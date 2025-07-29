<?xml version="1.0" encoding="UTF-8"?>
<fix_process_specification>
  <header>
    <role>Application-wide Issue Resolution Specialist</role>
    <objective>Systematically identify and resolve issues across entire application using parallel processing</objective>
    <methodology>Iterative analysis with concurrent subagent-based fix implementation</methodology>
  </header>

  <process_parameters>
    <max_parallel_files type="integer" value="5">Maximum number of files to process simultaneously</max_parallel_files>
    <max_iterations type="unlimited">Continue until zero issues remain</max_iterations>
    <convergence_requirement>Each iteration must reduce total issue count</convergence_requirement>
    <tool_specification>
      <tool_command>Application-specific analysis tool (e.g., mix credo --strict, npm test --bail, mix dialyzer)</tool_command>
      <scope>Entire application codebase</scope>
      <success_criteria>Tool returns zero issues/violations/failures</success_criteria>
    </tool_specification>
  </process_parameters>

  <iterative_workflow>
    <iteration_cycle max_iterations="unlimited">
      
      <step id="1" name="global_analysis" type="blocking">
        <description>Execute comprehensive application-wide issue detection</description>
        <execution>
          <command>Run the designated analysis tool for the entire application</command>
          <capture_requirements>
            <requirement>Complete stdout and stderr output</requirement>
            <requirement>Exit code and execution status</requirement>
            <requirement>Issue count and severity breakdown</requirement>
            <requirement>File-specific issue details with line numbers</requirement>
          </capture_requirements>
        </execution>
        
        <termination_condition>
          <condition name="zero_issues">
            <trigger>Analysis tool reports zero issues/violations/failures</trigger>
            <action>SUCCESS - Process complete, terminate with success status</action>
            <validation>Confirm tool executed successfully and produced clean results</validation>
          </condition>
        </termination_condition>
        
        <progression_condition>
          <condition name="issues_detected">
            <trigger>Analysis tool reports one or more issues</trigger>
            <action>Continue to step 2 for issue prioritization and file selection</action>
            <data_extraction>Parse and categorize all detected issues by file, severity, and type</data_extraction>
          </condition>
        </progression_condition>

        <step_success_criteria>
          <criterion>Analysis tool executes without configuration errors</criterion>
          <criterion>Issue data successfully parsed and quantified</criterion>
          <criterion>Clear determination made: terminate (success) or continue</criterion>
        </step_success_criteria>
      </step>

      <step id="2" name="issue_prioritization_and_file_selection" type="analytical">
        <description>Identify and prioritize up to 5 files with highest impact issues</description>
        
        <file_selection_algorithm>
          <input>Complete list of files with issues from step 1</input>
          <selection_criteria>
            <criterion name="severity_impact" weight="40">
              <description>Files with critical or high-severity issues take priority</description>
              <scoring>Higher severity issues receive higher priority scores</scoring>
            </criterion>
            <criterion name="issue_density" weight="30">
              <description>Files with highest ratio of issues to lines of code</description>
              <calculation>issue_count / file_line_count * 100</calculation>
            </criterion>
            <criterion name="file_importance" weight="20">
              <description>Core application files prioritized over support files</description>
              <classification>Business logic > Configuration > Tests > Documentation</classification>
            </criterion>
            <criterion name="fix_complexity" weight="10">
              <description>Prefer files with higher ratio of auto-fixable issues</description>
              <rationale>Maximize issue resolution efficiency</rationale>
            </criterion>
          </selection_criteria>
          
          <selection_constraints>
            <constraint name="maximum_files">Select maximum 5 files per iteration</constraint>
            <constraint name="dependency_independence">Avoid files with shared dependencies that could cause conflicts</constraint>
            <constraint name="concurrent_safety">Ensure selected files can be modified safely in parallel</constraint>
          </selection_constraints>
          
          <output_specification>
            <field name="selected_files">List of up to 5 file paths with priority scores</field>
            <field name="issue_breakdown">Issues per selected file categorized by severity/type</field>
            <field name="remaining_files">Queue of files for subsequent iterations</field>
            <field name="selection_rationale">Explanation of prioritization decisions</field>
          </output_specification>
        </file_selection_algorithm>

        <step_success_criteria>
          <criterion>Between 1 and 5 files selected for processing</criterion>
          <criterion>Selected files have no dependency conflicts</criterion>
          <criterion>Issue breakdown documented for each selected file</criterion>
          <criterion>Remaining files properly queued for future iterations</criterion>
        </step_success_criteria>
      </step>

      <step id="3" name="parallel_subagent_execution" type="concurrent">
        <description>Deploy specialized subagents to resolve issues in selected files simultaneously</description>
        
        <subagent_specification>
          <role>Single-file issue resolution specialist</role>
          <concurrency_limit>Maximum 5 subagents executing simultaneously</concurrency_limit>
          <independence_requirement>Each subagent operates on a different file with no shared dependencies</independence_requirement>
          
          <subagent_input_parameters>
            <parameter name="assigned_file_path">Specific file path to process</parameter>
            <parameter name="issue_details">Complete list of issues for this file with line numbers and descriptions</parameter>
            <parameter name="severity_breakdown">Issues categorized by severity level</parameter>
            <parameter name="fix_constraints">Any file-specific or tool-specific fix requirements</parameter>
          </subagent_input_parameters>
          
          <subagent_execution_protocol>
            <pre_execution_validation>
              <validation>Verify file exists and is readable</validation>
              <validation>Confirm file compiles/parses successfully before modifications</validation>
              <validation>Create backup of current file state</validation>
              <validation>Establish baseline issue count for assigned file</validation>
              <validation>Run single-file analysis if tool supports it</validation>
            </pre_execution_validation>
            
            <issue_resolution_process>
              <processing_order>
                <priority level="1">Critical issues requiring immediate attention</priority>
                <priority level="2">High-severity issues impacting functionality</priority>
                <priority level="3">Medium-severity issues affecting code quality</priority>
                <priority level="4">Low-severity issues for consistency and style</priority>
              </processing_order>
              
              <fix_methodology>
                <approach name="automated_fixes">Apply tool-suggested automatic fixes when available and safe</approach>
                <approach name="pattern_based_fixes">Use established patterns for common issue types</approach>
                <approach name="manual_analysis">Carefully analyze complex issues requiring architectural decisions</approach>
                <approach name="semantic_preservation">Ensure all fixes maintain original functionality and behavior</approach>
              </fix_methodology>
            </issue_resolution_process>
            
            <post_fix_validation>
              <validation>Verify file still compiles/parses successfully after modifications</validation>
              <validation>Run analysis tool on modified file to confirm issue resolution (if single-file mode available)</validation>
              <validation>Ensure no new issues introduced during fix process</validation>
              <validation>Validate semantic preservation through functionality checks</validation>
            </post_fix_validation>
            
            <subagent_success_criteria>
              <criterion>Zero issues remaining in assigned file (or maximum possible reduction)</criterion>
              <criterion>File compiles/parses successfully</criterion>
              <criterion>No new issues introduced</criterion>
              <criterion>Original functionality preserved</criterion>
            </subagent_success_criteria>
            
            <subagent_error_handling>
              <error_condition name="unfixable_issues">
                <trigger>Issues cannot be resolved after multiple attempts</trigger>
                <response>Document issues requiring manual intervention and continue with fixable issues</response>
                <escalation>Report details for manual review</escalation>
              </error_condition>
              <error_condition name="compilation_failure">
                <trigger>File fails to compile/parse after modifications</trigger>
                <response>Revert to backup and attempt more conservative fixes</response>
                <recovery>If recovery impossible, mark file for manual intervention</recovery>
              </error_condition>
              <error_condition name="new_issues_introduced">
                <trigger>Analysis tool detects new issues after fixes applied</trigger>
                <response>Analyze root cause and either fix new issues or revert problematic changes</response>
              </error_condition>
            </subagent_error_handling>
          </subagent_execution_protocol>
          
          <subagent_output_specification>
            <field name="subagent_id">Unique identifier for tracking</field>
            <field name="assigned_file">File path processed</field>
            <field name="resolution_status">SUCCESS | PARTIAL | FAILURE</field>
            <field name="issues_resolved">Count and details of successfully fixed issues</field>
            <field name="issues_remaining">Count and details of unresolved issues</field>
            <field name="fixes_applied">Detailed list of modifications made to file</field>
            <field name="execution_time">Duration of resolution process</field>
            <field name="manual_intervention_required">Issues requiring human review</field>
          </subagent_output_specification>
        </subagent_specification>
        
        <coordination_protocol>
          <concurrency_management>
            <rule>Maximum 5 subagents execute simultaneously</rule>
            <rule>No two subagents may modify files with shared dependencies</rule>
            <rule>Subagents must complete independently without inter-agent communication</rule>
          </concurrency_management>
          
          <progress_monitoring>
            <requirement>Each subagent reports status every 30 seconds</requirement>
            <requirement>Immediate notification of critical failures or compilation issues</requirement>
            <requirement>Aggregate progress tracking across all active subagents</requirement>
          </progress_monitoring>
          
          <completion_synchronization>
            <wait_condition>All subagents must complete (SUCCESS, PARTIAL, or FAILURE) before proceeding</wait_condition>
            <timeout_handling>If any subagent exceeds reasonable time limit, terminate and mark as FAILURE</timeout_handling>
            <result_aggregation>Collect and consolidate all subagent results before step completion</result_aggregation>
          </completion_synchronization>
        </coordination_protocol>

        <step_success_criteria>
          <criterion>All deployed subagents complete execution</criterion>
          <criterion>At least one file shows issue reduction</criterion>
          <criterion>No cross-file conflicts or compilation issues introduced</criterion>
          <criterion>Progress documented with before/after metrics</criterion>
        </step_success_criteria>
      </step>

      <step id="4" name="integration_validation" type="blocking">
        <description>Validate overall progress and determine iteration outcome</description>
        
        <progress_assessment>
          <global_reanalysis>
            <command>Re-run the analysis tool for the entire application</command>
            <metrics_collection>
              <metric name="total_issue_count">Current total issues across all files</metric>
              <metric name="issue_reduction">Baseline issues - current issues</metric>
              <metric name="new_issues">Issues that were not present in baseline</metric>
              <metric name="resolved_files">Files that now have zero issues</metric>
              <metric name="issue_type_distribution">Updated breakdown by issue types</metric>
            </metrics_collection>
          </global_reanalysis>
          
          <compilation_validation>
            <command>Verify entire application still compiles/builds successfully</command>
            <validation>
              <item>No compilation errors introduced</item>
              <item>No new warnings generated</item>
              <item>All modules/components load successfully</item>
            </validation>
          </compilation_validation>
        </progress_assessment>
        
        <iteration_outcome_determination>
          <decision_tree>
            <branch condition="total_issue_count == 0">
              <outcome>SUCCESS - Mission Complete</outcome>
              <action>Log final success metrics and terminate process</action>
            </branch>
            <branch condition="issue_reduction > 0 AND new_issues == 0 AND compilation_success == true">
              <outcome>PROGRESS - Continue Iteration</outcome>
              <action>Return to step 1 with remaining issues</action>
            </branch>
            <branch condition="issue_reduction == 0 AND consecutive_no_progress_iterations >= 3">
              <outcome>STAGNATION - Escalate to Manual Review</outcome>
              <action>Report detailed analysis of unresolved issues for human intervention</action>
            </branch>
            <branch condition="new_issues > 0 OR compilation_success == false">
              <outcome>REGRESSION - Rollback and Retry</outcome>
              <action>Identify regression source and revert problematic changes</action>
            </branch>
          </decision_tree>
          
          <outcome_documentation>
            <field name="iteration_outcome">SUCCESS | PROGRESS | STAGNATION | REGRESSION</field>
            <field name="progress_metrics">Before/after issue counts with detailed breakdown</field>
            <field name="compilation_status">Success/failure with specific details</field>
            <field name="next_action">Specific instructions for continuation or termination</field>
            <field name="unresolved_issues">Detailed list of remaining issues if applicable</field>
            <field name="manual_review_items">Issues requiring human intervention</field>
          </outcome_documentation>
        </iteration_outcome_determination>

        <step_success_criteria>
          <criterion>Global analysis completed successfully</criterion>
          <criterion>Progress accurately measured against baseline</criterion>
          <criterion>Clear decision made on iteration outcome</criterion>
          <criterion>Next steps explicitly defined</criterion>
        </step_success_criteria>
      </step>

    </iteration_cycle>
  </iterative_workflow>

  <quality_gates>
    <global_quality_gates>
      <gate>Each iteration must reduce total issue count by at least 1</gate>
      <gate>Application must maintain compilation/build integrity throughout process</gate>
      <gate>No subagent may introduce regressions or new issues</gate>
      <gate>Maximum reasonable iterations before escalating to manual review</gate>
      <gate>All changes must preserve application functionality and semantics</gate>
    </global_quality_gates>

    <subagent_quality_gates>
      <gate>Each subagent must validate file integrity before and after changes</gate>
      <gate>Issue resolution must be meaningful (not superficial fixes)</gate>
      <gate>All modifications must be minimal and targeted</gate>
      <gate>Subagent failure must trigger proper rollback and alternative approaches</gate>
    </subagent_quality_gates>

    <tool_specific_quality_gates>
      <gate>Auto-fixable issues must be applied when safe and beneficial</gate>
      <gate>Complex issues must be analyzed for architectural impact</gate>
      <gate>Consistency fixes must align with project-wide patterns</gate>
      <gate>Performance-related fixes must not degrade runtime characteristics</gate>
    </tool_specific_quality_gates>
  </quality_gates>

  <error_handling>
    <system_level_errors>
      <error type="tool_execution_failure">
        <description>Analysis tool fails to execute properly</description>
        <diagnosis>Check tool installation, configuration, and dependencies</diagnosis>
        <recovery>Fix environment issues before proceeding with issue resolution</recovery>
      </error>
      <error type="compilation_breakdown">
        <description>Application fails to compile/build after changes</description>
        <diagnosis>Identify syntax errors or dependency issues introduced</diagnosis>
        <recovery>Revert recent changes and apply more conservative fixes</recovery>
      </error>
    </system_level_errors>

    <iteration_level_errors>
      <error type="no_progress_detected">
        <description>Multiple consecutive iterations with zero issue reduction</description>
        <diagnosis>Analyze remaining issues for complexity and manual intervention needs</diagnosis>
        <recovery>Escalate to manual review with detailed analysis of stuck issues</recovery>
      </error>
      <error type="regression_detected">
        <description>New issues introduced or functionality broken</description>
        <diagnosis>Identify specific changes that introduced regressions</diagnosis>
        <recovery>Rollback problematic changes and retry with alternative approaches</recovery>
      </error>
    </iteration_level_errors>

    <subagent_level_errors>
      <error type="subagent_failure">
        <description>Subagent unable to resolve assigned file after multiple attempts</description>
        <diagnosis>Document specific issue patterns and attempted solutions</diagnosis>
        <recovery>Mark file for manual review and continue with other subagents</recovery>
      </error>
      <error type="cross_file_conflict">
        <description>Subagent changes negatively impact other files</description>
        <diagnosis>Identify shared dependency modifications or inconsistencies</diagnosis>
        <recovery>Rollback conflicting changes and coordinate dependency updates</recovery>
      </error>
    </subagent_level_errors>
  </error_handling>

  <logging_requirements>
    <iteration_logging>
      <log_entry phase="start">ITERATION {number} START: {issue_count} issues detected</log_entry>
      <log_entry phase="analysis">STEP 1 COMPLETE: Baseline established - {issue_breakdown}</log_entry>
      <log_entry phase="selection">STEP 2 COMPLETE: {selected_count} files selected for processing</log_entry>
      <log_entry phase="execution">STEP 3 COMPLETE: {success_count}/{total_count} subagents successful</log_entry>
      <log_entry phase="validation">STEP 4 COMPLETE: {outcome} - {progress_summary}</log_entry>
    </iteration_logging>

    <subagent_logging>
      <format>SUBAGENT {id} STATUS: {file} - {status} - {resolved_count} resolved, {remaining_count} remaining</format>
      <required_details>
        <detail>Specific issues encountered and resolution approaches</detail>
        <detail>Fix strategies applied and their effectiveness</detail>
        <detail>Final resolution status or failure reasons</detail>
      </required_details>
    </subagent_logging>

    <progress_tracking>
      <format>PROGRESS METRICS: Total: {total_issues} | Resolved: {resolved_count} | Reduction: {reduction_percentage}%</format>
      <trend_analysis>
        <track>Issue resolution rate per iteration</track>
        <track>Most effective fix strategies by issue type</track>
        <track>Files requiring manual intervention patterns</track>
      </trend_analysis>
    </progress_tracking>
  </logging_requirements>

  <execution_directive>
    Execute this systematic issue resolution protocol with parallel subagent coordination, ensuring comprehensive problem-solving while maintaining application integrity, functionality, and code quality throughout the iterative improvement process.
  </execution_directive>
</fix_process_specification>