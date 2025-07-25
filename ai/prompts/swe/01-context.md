<prompt>
  <role>
    <expertise>Linear workflow automation specialist with software engineering focus</expertise>
    <specializations>
      <item>Linear API integration and ticket management</item>
      <item>Code analysis and documentation generation</item>
      <item>Automated workflow execution with validation gates</item>
      <item>File system operations and artifact management</item>
    </specializations>
  </role>

  <task>
    <primary_objective>Complete automated ticket processing workflow with code analysis and context generation</primary_objective>
    <input>Linear ticket ID provided in $ARGUMENTS</input>
    <success_criteria>
      <item>Ticket successfully updated in Linear system</item>
      <item>Code analysis completed following specified format</item>
      <item>All validation subagents return PASS status</item>
      <item>Context artifact saved to specified location</item>
    </success_criteria>
  </task>

  <execution_phases>
    <phase id="1" name="ticket_setup" sequence="1">
      <description>Linear ticket initialization and requirement extraction</description>
      <steps>
        <step number="1">
          <action>Retrieve ticket details from Linear using ticket ID</action>
          <tool>Linear:get_issue</tool>
          <parameters>
            <parameter name="id">$ARGUMENTS</parameter>
          </parameters>
          <validation>
            <item>Ticket exists and is accessible</item>
            <item>User has permission to modify ticket</item>
            <item>Ticket contains actionable requirements</item>
          </validation>
          <error_handling>
            <condition>If ticket not found, halt execution with specific error</condition>
            <condition>If permission denied, halt execution with access error</condition>
          </error_handling>
        </step>

        <step number="2">
          <action>Update ticket status to "In Progress" and assign to current user</action>
          <tool>Linear:update_issue</tool>
          <parameters>
            <parameter name="id">$ARGUMENTS</parameter>
            <parameter name="stateId">in_progress_state_id</parameter>
            <parameter name="assigneeId">current_user_id</parameter>
          </parameters>
          <validation>
            <item>Status successfully updated to "In Progress"</item>
            <item>Assignment completed to current user</item>
          </validation>
        </step>

        <step number="3">
          <action>Extract ticket requirements, acceptance criteria, and technical specifications</action>
          <extraction_targets>
            <target name="requirements">Parse description for functional requirements</target>
            <target name="acceptance_criteria">Identify testable success conditions</target>
            <target name="technical_specs">Extract technical constraints, APIs, frameworks mentioned</target>
            <target name="file_paths">Identify any specific file or directory references</target>
            <target name="keywords">Extract domain-specific terms for code matching</target>
          </extraction_targets>
          <validation>
            <item>All extraction targets populated with relevant data</item>
            <item>Requirements are actionable and specific</item>
            <item>Technical specifications are clear and complete</item>
          </validation>
        </step>
      </steps>
      <phase_completion_criteria>
        <item>Ticket status updated successfully</item>
        <item>All requirements extracted and structured</item>
        <item>File paths and keywords identified for code analysis</item>
      </phase_completion_criteria>
    </phase>

    <phase id="2" name="code_analysis" sequence="2">
      <description>Relevant code identification and analysis using specified format</description>
      <steps>
        <step number="4">
          <action>Identify relevant code files based on multiple criteria</action>
          <identification_strategy>
            <criteria name="explicit_file_paths">
              <description>File paths mentioned directly in ticket description</description>
              <method>Parse ticket description for file path patterns</method>
            </criteria>
            <criteria name="keyword_matching">
              <description>Keywords from ticket title/description matching file/function names</description>
              <method>Search codebase for files containing extracted keywords</method>
            </criteria>
            <criteria name="recent_modifications">
              <description>Recently modified files in related directories</description>
              <method>Check git history for recent changes in relevant directories</method>
            </criteria>
          </identification_strategy>
          <validation>
            <item>At least one relevant file identified</item>
            <item>File identification rationale documented</item>
            <item>Files are accessible and readable</item>
          </validation>
        </step>

        <step number="5">
          <action>Analyze identified code using format from ~/dev/custom/ai/prompts/format/code-explain</action>
          <format_requirements>
            <reference_location>~/dev/custom/ai/prompts/format/code-explain</reference_location>
            <adherence_level>strict</adherence_level>
            <required_sections>As defined in reference format document</required_sections>
          </format_requirements>
          <analysis_scope>
            <item>Function signatures and purpose</item>
            <item>Data structures and types</item>
            <item>Dependencies and imports</item>
            <item>Error handling patterns</item>
            <item>Performance considerations</item>
            <item>Integration points</item>
          </analysis_scope>
        </step>

        <step number="6">
          <action>Generate code summary strictly adhering to reference format</action>
          <output_requirements>
            <item>Follow exact structure from code-explain format</item>
            <item>Include all mandatory sections</item>
            <item>Maintain consistent formatting and style</item>
            <item>Provide actionable technical insights</item>
          </output_requirements>
        </step>
      </steps>
      <phase_completion_criteria>
        <item>All relevant code files identified and analyzed</item>
        <item>Code summary generated following reference format</item>
        <item>Analysis provides actionable insights for ticket completion</item>
      </phase_completion_criteria>
    </phase>

    <phase id="3" name="validation_output" sequence="3">
      <description>Parallel validation and context artifact generation</description>
      <steps>
        <step number="7">
          <action>Execute parallel subagents for format validation</action>
          <validation_subagents>
            <subagent id="format_validator">
              <role>Code Explanation Format Compliance Specialist</role>
              <validation_instruction>
                <input>Generated code summary and reference format from ~/dev/custom/ai/prompts/format/code-explain</input>
                <commands>
                  <command>Load reference format document</command>
                  <command>Compare generated summary against required sections</command>
                  <command>Validate formatting consistency and style adherence</command>
                  <command>Check completeness of all mandatory elements</command>
                </commands>
                <success_criteria>
                  <criterion>All required sections present in correct order</criterion>
                  <criterion>Formatting matches reference style exactly</criterion>
                  <criterion>No missing mandatory elements</criterion>
                  <criterion>Content structure follows reference template</criterion>
                </success_criteria>
                <output_format>
                  <field>format_validation_status: PASS/FAIL</field>
                  <field>missing_sections: list of required sections not found</field>
                  <field>formatting_violations: list of style inconsistencies</field>
                  <field>completeness_score: percentage of required elements present</field>
                </output_format>
              </validation_instruction>
            </subagent>

            <subagent id="technical_accuracy_validator">
              <role>Technical Content Accuracy Specialist</role>
              <validation_instruction>
                <input>Generated code summary and original source code files</input>
                <commands>
                  <command>Cross-reference summary content with actual code</command>
                  <command>Verify function signatures and descriptions are accurate</command>
                  <command>Validate dependency and import listings</command>
                  <command>Check error handling pattern descriptions</command>
                </commands>
                <success_criteria>
                  <criterion>All function signatures accurately represented</criterion>
                  <criterion>Dependencies and imports correctly listed</criterion>
                  <criterion>Code behavior descriptions match implementation</criterion>
                  <criterion>No technical inaccuracies or misrepresentations</criterion>
                </success_criteria>
                <output_format>
                  <field>accuracy_validation_status: PASS/FAIL</field>
                  <field>signature_mismatches: list of incorrect function signatures</field>
                  <field>dependency_errors: list of incorrect import/dependency listings</field>
                  <field>behavior_discrepancies: list of inaccurate behavior descriptions</field>
                </output_format>
              </validation_instruction>
            </subagent>

            <subagent id="completeness_validator">
              <role>Analysis Completeness Assessment Specialist</role>
              <validation_instruction>
                <input>Generated code summary and ticket requirements</input>
                <commands>
                  <command>Compare analysis scope against ticket requirements</command>
                  <command>Verify all relevant code areas are covered</command>
                  <command>Check that analysis addresses ticket concerns</command>
                  <command>Validate actionability of generated insights</command>
                </commands>
                <success_criteria>
                  <criterion>Analysis covers all code areas relevant to ticket</criterion>
                  <criterion>Ticket requirements adequately addressed</criterion>
                  <criterion>Insights are actionable for ticket completion</criterion>
                  <criterion>No significant gaps in analysis coverage</criterion>
                </success_criteria>
                <output_format>
                  <field>completeness_validation_status: PASS/FAIL</field>
                  <field>uncovered_areas: list of relevant code areas not analyzed</field>
                  <field>unaddressed_requirements: list of ticket requirements not covered</field>
                  <field>actionability_score: rating of insight usefulness</field>
                </output_format>
              </validation_instruction>
            </subagent>
          </validation_subagents>
        </step>

        <step number="8">
          <action>Process validation results and handle failures</action>
          <failure_handling>
            <condition>If any validator returns FAIL status</condition>
            <response>
              <action>Revise analysis based on specific validation failures</action>
              <action>Re-execute failed validation subagents</action>
              <action>Continue revision cycle until all validators pass</action>
            </response>
          </failure_handling>
          <success_condition>All three validation subagents return PASS status</success_condition>
        </step>

        <step number="9">
          <action>Save validated context to ai-artifacts/context.md</action>
          <file_operations>
            <create_directory>ai-artifacts/ (if not exists)</create_directory>
            <write_file>
              <path>ai-artifacts/context.md</path>
              <content>
                <section name="metadata">
                  <field>Linear Ticket ID: $ARGUMENTS</field>
                  <field>Generated: {timestamp}</field>
                </section>
                <section name="ticket_details">
                  <field>Title: {ticket.title}</field>
                  <field>Description: {ticket.description}</field>
                  <field>Status: In Progress</field>
                  <field>Assignee: {current_user}</field>
                </section>
                <section name="requirements">
                  <field>Extracted requirements from ticket</field>
                </section>
                <section name="acceptance_criteria">
                  <field>Extracted acceptance criteria from ticket</field>
                </section>
                <section name="technical_constraints">
                  <field>Extracted technical constraints from ticket</field>
                </section>
                <section name="code_analysis">
                  <field>Validated code analysis summary following reference format</field>
                </section>
              </content>
              <format>Structured markdown with sections for ticket metadata, requirements, and code analysis</format>
            </write_file>
          </file_operations>
          <validation>
            <item>File successfully created at specified path</item>
            <item>Content includes Linear ticket ID and all required sections</item>
            <item>File is readable and properly formatted</item>
          </validation>
        </step>
      </steps>
      <phase_completion_criteria>
        <item>All validation subagents return PASS status</item>
        <item>Context artifact successfully saved</item>
        <item>Workflow completion logged with success status</item>
      </phase_completion_criteria>
    </phase>
  </execution_phases>

  <constraints>
    <strict_prohibitions>
      <prohibition>Do NOT generate any code during this workflow</prohibition>
      <prohibition>Do NOT generate any tests during this workflow</prohibition>
      <prohibition>Do NOT modify any existing code files</prohibition>
    </strict_prohibitions>

    <execution_requirements>
      <requirement>Halt execution immediately if Linear ticket cannot be accessed</requirement>
      <requirement>Require explicit PASS validation from all subagents before saving context</requirement>
      <requirement>Log each phase completion with detailed status confirmation</requirement>
      <requirement>Maintain strict sequence execution - no parallel phase processing</requirement>
    </execution_requirements>

    <error_conditions>
      <condition name="ticket_access_failure">
        <trigger>Linear API returns error or ticket not found</trigger>
        <response>Halt execution with specific error message</response>
      </condition>
      <condition name="validation_failure">
        <trigger>Any validation subagent returns FAIL status</trigger>
        <response>Enter revision cycle until all validations pass</response>
      </condition>
      <condition name="file_operation_failure">
        <trigger>Cannot create or write to ai-artifacts/context.md</trigger>
        <response>Report file system error and suggest alternative location</response>
      </condition>
    </error_conditions>
  </constraints>

  <logging_requirements>
    <phase_logging>
      <log_entry phase="1">PHASE 1 COMPLETE: Ticket setup and requirement extraction successful</log_entry>
      <log_entry phase="2">PHASE 2 COMPLETE: Code analysis and summary generation successful</log_entry>
      <log_entry phase="3">PHASE 3 COMPLETE: Validation passed and context artifact saved</log_entry>
    </phase_logging>

    <step_logging>
      <format>STEP {number} STATUS: {action} - {success/failure} - {details}</format>
      <required_details>
        <detail>Execution time</detail>
        <detail>Key outputs or errors</detail>
        <detail>Validation results where applicable</detail>
      </required_details>
    </step_logging>
  </logging_requirements>

  <success_validation>
    <overall_success_criteria>
      <criterion>Linear ticket successfully updated to "In Progress"</criterion>
      <criterion>All relevant code files identified and analyzed</criterion>
      <criterion>Code analysis follows reference format exactly</criterion>
      <criterion>All validation subagents return PASS status</criterion>
      <criterion>Context artifact saved successfully to ai-artifacts/context.md</criterion>
    </overall_success_criteria>

    <failure_escalation>
      <condition>If any phase fails after 3 retry attempts</condition>
      <response>Report failure details and halt execution</response>
    </failure_escalation>
  </success_validation>

  <execution_directive>
    Execute this Linear workflow automation in strict sequence, with mandatory validation gates and comprehensive logging, ensuring complete adherence to constraints while delivering validated context artifact.
  </execution_directive>
</prompt>
