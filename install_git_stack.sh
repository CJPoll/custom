#!/bin/bash

# Function to show a spinner for long-running operations
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    echo -n " "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Function to check network connectivity
check_network() {
    # Use curl instead of ping since ping requires special permissions
    if ! curl -s --connect-timeout 5 --max-time 10 -I https://github.com &> /dev/null; then
        echo "Error: No network connectivity. Please check your internet connection."
        return 1
    fi
    return 0
}

# Function to download the latest git-stack binary for Linux from GitHub releases
download_git_stack_binary() {
    local releases_url="https://github.com/gitext-rs/git-stack/releases/latest"
    local download_dir="$HOME/downloads/git-stack-install"
    
    echo "Fetching release information from $releases_url"
    
    # Check network connectivity
    check_network || return 1

    # Create the download directory if it doesn't exist
    if [ ! -w "$(dirname "$download_dir")" ]; then
        echo "Error: No write permission in $(dirname "$download_dir")."
        return 1
    fi
    
    mkdir -p "$download_dir" || {
        echo "Error: Failed to create directory $download_dir"
        return 1
    }
    echo "Created directory: $download_dir"
    
    # Get the releases page and follow redirects to get the actual version URL
    echo "⏳ Fetching release information..."
    local release_page=$(curl -sL "$releases_url" --fail --connect-timeout 10 --max-time 30 2>/tmp/curl_error)
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ] || [ -z "$release_page" ]; then
        echo "Error: Failed to fetch release page from GitHub"
        if [ -f /tmp/curl_error ] && [ -s /tmp/curl_error ]; then
            echo "  → $(cat /tmp/curl_error | head -n1)"
            rm -f /tmp/curl_error
        fi
        return 1
    fi
    
    local actual_url=$(curl -sI "$releases_url" 2>/dev/null | grep -i "^location:" | tr -d '\r' | cut -d' ' -f2)
    
    if [ -z "$actual_url" ]; then
        # If no redirect, use the original URL
        actual_url="$releases_url"
    fi
    
    echo "Release URL: $actual_url"
    
    # Extract download links matching the pattern "git-stack.*-linux.*.tar.gz"
    # GitHub uses /releases/download/ URLs for binary assets
    local download_links=$(echo "$release_page" | grep -oE 'href="[^"]*git-stack[^"]*-linux[^"]*\.tar\.gz"' | sed 's/href="//;s/"$//')
    
    if [ -z "$download_links" ]; then
        echo "No Linux tar.gz files found in the release page"
        echo "Trying alternative approach with GitHub API..."
        
        # Extract owner and repo from the URL
        local owner_repo=$(echo "$releases_url" | sed 's|https://github.com/||' | sed 's|/releases/.*||')
        local api_url="https://api.github.com/repos/$owner_repo/releases/latest"
        
        echo "Fetching from API: $api_url"
        
        # Get the download URL using GitHub API
        local api_response=$(curl -s "$api_url" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$api_response" ]; then
            echo "Error: Failed to fetch data from GitHub API"
            return 1
        fi
        download_links=$(echo "$api_response" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*git-stack[^"]*-linux[^"]*\.tar\.gz"' | cut -d'"' -f4)
    fi
    
    if [ -z "$download_links" ]; then
        echo "Error: No Linux tar.gz files found"
        return 1
    fi
    
    # Get the first matching download link
    local download_url=$(echo "$download_links" | head -n1)
    
    # Convert relative path to absolute URL if needed
    if [[ "$download_url" =~ ^/ ]]; then
        download_url="https://github.com$download_url"
    fi
    
    echo "Found download URL: $download_url"
    
    # Extract filename from URL
    local filename=$(basename "$download_url")
    local filepath="$download_dir/$filename"
    
    # Download the file with retry
    echo "Downloading $filename..."
    for i in {1..3}; do
        if curl -L -o "$filepath" "$download_url" --progress-bar --fail --connect-timeout 30 --max-time 300 2>/tmp/curl_error; then
            if [ -f "$filepath" ] && [ $(stat -c%s "$filepath") -gt 0 ]; then
                echo "Download complete: $filepath"
                return 0
            else
                echo "Downloaded file is invalid or empty. Attempt $i of 3."
                rm -f "$filepath" 2>/dev/null
            fi
        else
            echo "Attempt $i of 3 failed to download file."
            if [ -f /tmp/curl_error ]; then
                local curl_error=$(cat /tmp/curl_error 2>/dev/null)
                if [[ "$curl_error" =~ "Connection refused" ]]; then
                    echo "  → Connection refused. The server may be down."
                elif [[ "$curl_error" =~ "Could not resolve host" ]]; then
                    echo "  → DNS resolution failed. Check your network settings."
                elif [[ "$curl_error" =~ "Operation timed out" ]]; then
                    echo "  → Connection timed out. The server may be slow or unreachable."
                elif [[ "$curl_error" =~ "404" ]]; then
                    echo "  → File not found (404). The release URL may have changed."
                fi
                rm -f /tmp/curl_error
            fi
        fi
        sleep 2
    done
    
    echo "Error: Failed to download file after 3 attempts"
    return 1
}

# Function to extract and install git-stack binary
extract_and_install_git_stack() {
    local tar_gz_path="$1"
    local dest_dir="$HOME/.local/bin"
    local temp_extract_dir="$(mktemp -d)"

    if command -v git-stack &> /dev/null; then
        echo "Note: git-stack is already installed at $(which git-stack)."
        read -p "Do you want to overwrite it? (y/n): " choice
        if [ "$choice" != "y" ]; then
            echo "Skipping installation."
            rm -rf "$temp_extract_dir"
            return 0
        fi
    fi

    if [ ! -f "$tar_gz_path" ]; then
        echo "Error: File not found: $tar_gz_path"
        return 1
    fi
    
    # Validate tar.gz file
    if ! tar -tzf "$tar_gz_path" &>/dev/null; then
        echo "Error: The downloaded file appears to be corrupted or is not a valid tar.gz archive"
        return 1
    fi
    
    echo "⏳ Extracting git-stack from $tar_gz_path..."
    
    # Check if we have write permission to parent directory
    local parent_dir=$(dirname "$dest_dir")
    if [ ! -w "$parent_dir" ]; then
        echo "Error: No write permission in $parent_dir"
        echo "You may need to run this script with sudo or choose a different installation directory"
        rm -rf "$temp_extract_dir"
        return 1
    fi
    
    # Create destination directory if it doesn't exist
    if ! mkdir -p "$dest_dir"; then
        echo "Error: Failed to create destination directory $dest_dir"
        echo "Check if you have sufficient permissions"
        rm -rf "$temp_extract_dir"
        return 1
    fi
    
    # Extract to temporary directory with progress
    echo "📦 Extracting archive..."
    if ! tar -xzf "$tar_gz_path" -C "$temp_extract_dir" 2>/dev/null; then
        echo "Error: Failed to extract $tar_gz_path"
        echo "The archive may be corrupted or you may not have sufficient permissions"
        rm -rf "$temp_extract_dir"
        return 1
    fi
    
    # Find the git-stack binary in the extracted files
    local git_stack_binary=$(find "$temp_extract_dir" -type f -name "git-stack" -executable | head -n1)
    
    if [ -z "$git_stack_binary" ]; then
        echo "Error: git-stack binary not found in the archive"
        rm -rf "$temp_extract_dir"
        return 1
    fi
    
    echo "Found git-stack binary: $git_stack_binary"
    
    # Check if destination already exists and backup if needed
    if [ -f "$dest_dir/git-stack" ]; then
        echo "📋 Backing up existing git-stack binary..."
        mv "$dest_dir/git-stack" "$dest_dir/git-stack.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Move the binary to the destination directory
    if ! mv "$git_stack_binary" "$dest_dir/git-stack"; then
        echo "Error: Failed to move git-stack to $dest_dir"
        echo "Check if you have write permissions to $dest_dir"
        rm -rf "$temp_extract_dir"
        return 1
    fi
    
    # Set executable permissions
    chmod +x "$dest_dir/git-stack"
    
    # Clean up temporary extraction directory
    rm -rf "$temp_extract_dir"
    
    echo "✅ Successfully installed git-stack to $dest_dir/git-stack"
    
    # Check if dest_dir is in PATH
    if ! echo "$PATH" | grep -q "$dest_dir"; then
        echo ""
        echo "WARNING: $dest_dir is not in your PATH."
        echo "Add the following line to your shell configuration file (~/.bashrc, ~/.zshrc, etc.):"
        echo "  export PATH=\"$dest_dir:\$PATH\""
    fi
    
    return 0
}

# Main function to coordinate the installation
install_git_stack() {
    local download_dir="$HOME/downloads/git-stack-install"
    local success=false
    
    echo "Starting git-stack installation..."
    echo ""
    
    # Step 1: Download the binary
    if download_git_stack_binary; then
        echo ""
        echo "Download completed successfully."
        
        # Find the downloaded tar.gz file
        local tar_file=$(find "$download_dir" -name "git-stack*-linux*.tar.gz" -type f | sort -r | head -n1)
        
        if [ -z "$tar_file" ]; then
            echo "Error: Downloaded file not found in $download_dir"
        else
            echo "Found downloaded file: $tar_file"
            echo ""
            
            # Step 2: Extract and install
            if extract_and_install_git_stack "$tar_file"; then
                success=true
                echo ""
                echo "Installation completed successfully!"
                
                # Verify installation
                if command -v git-stack &> /dev/null; then
                    echo "git-stack version: $(git-stack --version 2>&1 | head -n1)"
                else
                    echo "Note: You may need to restart your shell or add ~/.local/bin to your PATH"
                fi
            else
                echo ""
                echo "Error: Failed to extract and install git-stack"
            fi
        fi
    else
        echo ""
        echo "Error: Failed to download git-stack"
    fi
    
    # Step 3: Clean up temporary files
    echo ""
    echo "Cleaning up temporary files..."
    if [ -d "$download_dir" ]; then
        if rm -rf "$download_dir"; then
            echo "Removed temporary directory: $download_dir"
        else
            echo "Warning: Failed to remove temporary directory: $download_dir"
            echo "You may want to remove it manually."
        fi
    fi
    
    echo ""
    if [ "$success" = true ]; then
        echo "✓ git-stack installation completed successfully!"
        return 0
    else
        echo "✗ git-stack installation failed."
        echo "Please check the error messages above and try again."
        return 1
    fi
}

# Run the main install function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    install_git_stack
fi
