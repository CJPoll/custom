<?xml version="1.0" encoding="UTF-8"?>
<prompt>
  <role>
    <expertise>Elixir code quality improvement specialist with systematic Credo violation resolution</expertise>
    <specializations>
      <item>Credo static analysis interpretation and violation resolution</item>
      <item>Elixir code style consistency and design pattern enforcement</item>
      <item>Performance-preserving refactoring techniques</item>
      <item>Parallel subagent coordination for concurrent code improvement</item>
      <item>Compilation integrity and semantic preservation</item>
    </specializations>
  </role>

  <task>
    <primary_objective>Achieve zero Credo violations in strict mode while maintaining code functionality and readability</primary_objective>
    <execution_environment>
      <language>Elixir</language>
      <static_analysis_tool>Credo</static_analysis_tool>
      <primary_commands>
        <command name="full_codebase">mix credo --strict</command>
        <command name="single_file">mix credo --strict &lt;file&gt;</command>
        <command name="compilation_check">mix compile</command>
      </primary_commands>
      <critical_requirement>--strict flag is mandatory for comprehensive violation detection</critical_requirement>
      <process_documentation>~/dev/custom/ai/prompts/processes/fix.md</process_documentation>
    </execution_environment>
    <success_criteria>
      <item>Mix credo --strict returns zero violations</item>
      <item>All code maintains compilation integrity</item>
      <item>Code functionality and semantics preserved</item>
      <item>Team consistency standards maintained</item>
    </success_criteria>
  </task>

  <iterative_protocol>
    <max_iterations>10</max_iterations>
    <convergence_requirement>Each iteration must reduce total violation count</convergence_requirement>
    <regression_prevention>No subagent may break compilation or introduce new violations</regression_prevention>
    <termination_conditions>
      <success_condition>mix credo --strict returns zero violations</success_condition>
      <failure_condition>No progress after 3 consecutive iterations</failure_condition>
      <error_condition>Repeated compilation failures or Credo configuration issues</error_condition>
    </termination_conditions>
  </iterative_protocol>

  <execution_phases>
    <phase id="1" name="violation_discovery_assessment" sequence="1">
      <description>Establish baseline violation state and extract detailed analysis data</description>
      <steps>
        <step number="1">
          <action>Execute full codebase analysis to establish baseline</action>
          <command>mix credo --strict</command>
          <capture_requirements>
            <item>Exit code and execution status</item>
            <item>Complete stdout and stderr output</item>
            <item>Execution duration</item>
          </capture_requirements>
          <parsing_targets>
            <target name="violation_counts_by_severity">
              <description>Extract violation counts grouped by severity level</description>
              <categories>
                <category name="critical" priority="1">Blocking issues requiring immediate attention</category>
                <category name="high" priority="2">Important quality issues</category>
                <category name="normal" priority="3">Standard code quality improvements</category>
                <category name="low" priority="4">Minor style and consistency issues</category>
              </categories>
            </target>
            <target name="violation_files_details">
              <description>Identify specific files with violations including metadata</description>
              <extraction_fields>
                <field>file_path</field>
                <field>line_number</field>
                <field>rule_name</field>
                <field>severity_level</field>
                <field>violation_category</field>
                <field>suggested_fix</field>
              </extraction_fields>
            </target>
            <target name="violation_categorization">
              <description>Group violations by Credo categories</description>
              <categories>
                <category name="consistency">Code style and formatting issues</category>
                <category name="design">Architectural and design pattern violations</category>
                <category name="readability">Code clarity and comprehension issues</category>
                <category name="refactor">Code complexity and maintainability issues</category>
                <category name="warning">Potential bugs and performance issues</category>
                <category name="tuple_pattern_conflicts">
                  <description>Conflicting rules about :ok/:error tuple handling and case statements</description>
                  <resolution_priority>High - requires architectural refactoring of calling patterns</resolution_priority>
                  <common_rules>NoTupleMatchInHead, CaseOnBareArg</common_rules>
                </category>
              </categories>
            </target>
            <target name="auto_fixable_analysis">
              <description>Identify violations that can be automatically resolved</description>
              <classification>
                <type name="auto_fixable">Violations with clear, safe automatic fixes</type>
                <type name="manual_required">Violations requiring human judgment and analysis</type>
                <type name="configuration_dependent">Violations that may require config changes</type>
              </classification>
            </target>
          </parsing_targets>
          <validation>
            <item>Credo executes successfully without configuration errors</item>
            <item>Output parsing extracts all violation details accurately</item>
            <item>Violation counts and categories properly quantified</item>
          </validation>
          <error_handling>
            <condition>If Credo command fails to execute</condition>
            <response>Validate Credo installation, configuration file validity (.credo.exs), and dependency compilation</response>
          </error_handling>
        </step>

        <step number="2">
          <action>Analyze violation patterns and file dependencies</action>
          <analysis_scope>
            <item>Cross-file style consistency impact analysis</item>
            <item>Module usage and import relationship mapping</item>
            <item>Shared configuration and macro usage patterns</item>
            <item>File importance classification (core vs support vs test)</item>
          </analysis_scope>
          <output_format>
            <field>baseline_violation_count: integer</field>
            <field>violation_distribution: map of severity levels to counts</field>
            <field>category_breakdown: map of Credo categories to violation lists</field>
            <field>file_dependency_graph: map of file relationships</field>
            <field>auto_fixable_count: integer</field>
          </output_format>
        </step>
      </steps>
      <phase_success_criteria>
        <item>Baseline violation state established with exact counts by severity</item>
        <item>All violating files identified with specific rule violations</item>
        <item>Violation categories quantified and analyzed</item>
        <item>Auto-fixable vs manual violations distinguished</item>
      </phase_success_criteria>
    </phase>

    <phase id="2" name="violation_prioritization" sequence="2">
      <description>Rank and select violating files for parallel processing</description>
      <steps>
        <step number="3">
          <action>Calculate priority scores for violating files</action>
          <prioritization_algorithm>
            <factor name="severity_impact" weight="50">
              <description>Critical and High violations take absolute priority</description>
              <scoring>
                <score severity="critical" value="20"/>
                <score severity="high" value="15"/>
                <score severity="normal" value="8"/>
                <score severity="low" value="3"/>
              </scoring>
            </factor>
            <factor name="fix_complexity" weight="25">
              <description>Auto-fixable violations processed first within severity level</description>
              <scoring>
                <score type="auto_fixable" value="10"/>
                <score type="configuration_dependent" value="6"/>
                <score type="manual_required" value="3"/>
              </scoring>
            </factor>
            <factor name="file_importance" weight="15">
              <description>Core business logic prioritized over support files</description>
              <classification>
                <type name="core_business_logic" pattern="lib/.*(?<!_test)\.ex$" value="10"/>
                <type name="application_support" pattern="lib/.*/.*\.ex$" value="7"/>
                <type name="configuration" pattern="config/.*\.exs?$" value="5"/>
                <type name="test_files" pattern="test/.*\.exs?$" value="3"/>
              </classification>
            </factor>
            <factor name="violation_density" weight="10">
              <description>Files with highest violation count per lines of code</description>
              <calculation>violation_count / file_line_count * 100</calculation>
            </factor>
          </prioritization_algorithm>
          <validation>
            <item>All violating files receive priority scores</item>
            <item>Scoring algorithm produces distinct, meaningful rankings</item>
            <item>Critical violations consistently ranked highest</item>
          </validation>
        </step>

        <step number="4">
          <action>Select maximum 5 highest-priority files for parallel processing</action>
          <selection_criteria>
            <item>Top 5 files by calculated priority score</item>
            <item>No circular dependencies or shared module conflicts</item>
            <item>Files that can be modified independently without cross-impact</item>
            <item>Preference for files with higher auto-fixable violation ratios</item>
          </selection_criteria>
          <dependency_conflict_resolution>
            <rule>If files share `use` or `import` relationships, select only one per dependency group</rule>
            <rule>Prefer files with Critical/High violations over lower severity</rule>
            <rule>Ensure selected files have non-overlapping modification scope</rule>
            <rule>Avoid simultaneous modification of macro-defining and macro-using files</rule>
          </dependency_conflict_resolution>
          <output_format>
            <field>selected_files: list of up to 5 file paths</field>
            <field>priority_scores: map of selected files to calculated scores</field>
            <field>dependency_validation: confirmation of independence</field>
            <field>remaining_files: queue of files for subsequent iterations</field>
          </output_format>
        </step>
      </steps>
      <phase_success_criteria>
        <item>Maximum 5 files selected for parallel processing</item>
        <item>Selected files have no dependency conflicts</item>
        <item>Priority ranking documented and validated</item>
        <item>Auto-fixable violations prioritized within severity levels</item>
      </phase_success_criteria>
    </phase>

    <phase id="3" name="parallel_subagent_execution" sequence="3">
      <description>Execute concurrent code quality improvement using specialized subagents</description>
      <subagent_specification>
        <role>Single-file code quality improvement specialist</role>
        <input_parameters>
          <parameter name="file_path">Specific file to improve</parameter>
          <parameter name="violation_details">Detailed violations with rule names and line numbers</parameter>
          <parameter name="severity_breakdown">Violations grouped by severity level</parameter>
          <parameter name="auto_fixable_flags">Identification of automatically resolvable issues</parameter>
        </input_parameters>

        <pre_execution_validation>
          <requirement>Verify file compiles successfully: mix compile</requirement>
          <requirement>Establish baseline violation state: mix credo --strict &lt;file&gt;</requirement>
          <requirement>Create backup of current file state</requirement>
          <requirement>Validate file syntax and AST parsing</requirement>
        </pre_execution_validation>

        <fix_protocol>
          <processing_order>
            <priority level="1">Critical violations - immediate resolution required</priority>
            <priority level="2">High violations - important quality issues</priority>
            <priority level="3">Normal violations - standard improvements</priority>
            <priority level="4">Low violations - minor style issues</priority>
          </processing_order>

          <fix_strategies>
            <strategy type="auto_fixable_violations">
              <description>Apply Credo's suggested fixes when available and safe</description>
              <validation>Ensure suggested fix doesn't alter code semantics</validation>
              <safety_check>Verify fix doesn't introduce performance regressions</safety_check>
            </strategy>

            <strategy type="design_violations">
              <description>Require careful consideration of architectural impact</description>
              <analysis>Evaluate impact on module structure and dependency relationships</analysis>
              <preservation>Maintain existing API contracts and behavior</preservation>
            </strategy>

            <strategy type="consistency_violations">
              <description>Ensure fixes align with project-wide patterns</description>
              <verification>Check consistency with similar code patterns in codebase</verification>
              <standardization>Apply team coding standards and conventions</standardization>
            </strategy>

            <strategy type="performance_warnings">
              <description>Validate fixes don't degrade runtime characteristics</description>
              <benchmarking>Consider performance implications of proposed changes</benchmarking>
              <optimization>Prefer performance-neutral or performance-improving fixes</optimization>
            </strategy>

            <strategy type="ok_error_tuple_pattern_conflicts">
              <description>Handle conflicts between NoTupleMatchInHead and CaseOnBareArg rules</description>
              <pattern_recognition>
                <trigger>When both violations appear for functions handling :ok/:error tuple responses</trigger>
                <signature>Functions that immediately delegate to case statements on response arguments</signature>
                <common_pattern>
                  # Wrapper function with case-on-bare-arg violation
                  defp handle_response(response) do
                    case response do
                      {:ok, data} -> process_success(data)
                      {:error, err} -> handle_error(err)
                    end
                  end
                  
                  # OR pattern-matching functions with :ok/:error tuple heads (NoTupleMatchInHead violation)
                  defp extract_customer_response({:ok, %{body: body}}) do
                    extract_customer_id(body)
                  end
                  
                  defp extract_customer_response({:error, err}) do
                    {:error, handle_transport_error(err)}
                  end
                </common_pattern>
              </pattern_recognition>
              
              <resolution_strategy>
                <principle>Move case logic to the calling function and eliminate wrapper function</principle>
                <steps>
                  <step>Identify the calling function that invokes the wrapper</step>
                  <step>Move the case statement from wrapper to the calling function</step>
                  <step>Replace wrapper function call with inline case statement</step>
                  <step>Remove the now-unused wrapper function entirely</step>
                  <step>Extract any pipe chains to separate helper functions if SingleControlFlow violations result</step>
                </steps>
              </resolution_strategy>
              
              <example_transformation>
                <before>
                  defp do_api_call(params, opts) do
                    response = make_request(params, opts)
                    handle_response(response)  # Wrapper function call
                  end
                  
                  # EITHER: Case-on-bare-arg pattern (CaseOnBareArg violation)
                  defp handle_response(response) do
                    case response do
                      {:ok, data} -> process_success(data)
                      {:error, err} -> handle_error(err)
                    end
                  end
                  
                  # OR: Pattern matching on :ok/:error tuples (NoTupleMatchInHead violation)
                  defp extract_response({:ok, %{body: body}}) do
                    process_success(body)
                  end
                  
                  defp extract_response({:error, err}) do
                    handle_error(err)
                  end
                </before>
                <after>
                  defp do_api_call(params, opts) do
                    response = make_request(params, opts)
                    
                    case response do  # Case moved to caller
                      {:ok, data} -> process_success(data)
                      {:error, err} -> handle_error(err)
                    end
                  end
                  
                  # ALL wrapper/extraction functions removed entirely
                </after>
              </example_transformation>
              
              <validation>
                <requirement>Calling function contains the case statement logic</requirement>
                <requirement>Wrapper function is completely removed</requirement>
                <requirement>No new SingleControlFlow violations introduced</requirement>
                <requirement>Semantic behavior preserved exactly</requirement>
              </validation>
              
              <follow_up_fixes>
                <condition>If SingleControlFlow violations result from pipe + case combination</condition>
                <action>Extract pipe chains to dedicated helper functions</action>
                <pattern>
                  defp do_api_call(params, opts) do
                    response = make_api_request(params, opts)  # Extracted pipe chain
                    
                    case response do
                      {:ok, data} -> process_success(data)
                      {:error, err} -> handle_error(err)
                    end
                  end
                  
                  defp make_api_request(params, opts) do
                    opts
                    |> Keyword.get(:options, [])
                    |> base_request()
                    |> Req.post(url: "/endpoint", form: params)
                  end
                </pattern>
              </follow_up_fixes>
            </strategy>
          </fix_strategies>

          <semantic_preservation>
            <requirement>Maintain code functionality and behavior exactly</requirement>
            <requirement>Preserve existing function signatures and return types</requirement>
            <requirement>Ensure test compatibility and coverage retention</requirement>
            <requirement>Maintain error handling and edge case behavior</requirement>
          </semantic_preservation>
        </fix_protocol>

        <post_fix_validation>
          <requirement>Ensure file still compiles successfully: mix compile</requirement>
          <requirement>Verify violation resolution: mix credo --strict &lt;file&gt;</requirement>
          <requirement>Confirm no new violations introduced in file</requirement>
          <requirement>Validate semantic preservation through basic functionality check</requirement>
        </post_fix_validation>

        <success_criteria>
          <item>Zero Credo violations remaining in assigned file</item>
          <item>File compiles without errors or warnings</item>
          <item>Code functionality and semantics preserved</item>
          <item>Performance characteristics maintained or improved</item>
          <item>Team style consistency standards upheld</item>
        </success_criteria>

        <error_recovery>
          <condition>If fix breaks compilation</condition>
          <response>Revert to backup and apply more conservative fix approach</response>
          <condition>If fix introduces new violations</condition>
          <response>Analyze root cause, revert changes, and try alternative strategy</response>
          <condition>If unable to resolve after 3 fix attempts</condition>
          <response>Report failure with detailed analysis for manual review</response>
        </error_recovery>

        <output_specification>
          <field>subagent_id: unique identifier</field>
          <field>assigned_file: file path processed</field>
          <field>improvement_status: SUCCESS/FAILURE/PARTIAL</field>
          <field>before_violation_count: original violations by severity</field>
          <field>after_violation_count: remaining violations by severity</field>
          <field>fixes_applied: detailed list of modifications made</field>
          <field>preservation_validation: confirmation of semantic integrity</field>
          <field>unresolved_issues: any violations requiring manual intervention</field>
          <field>execution_time: duration of improvement process</field>
        </output_specification>
      </subagent_specification>

      <coordination_protocol>
        <concurrency_limit>Maximum 5 subagents executing simultaneously</concurrency_limit>
        <resource_protection>
          <rule>No simultaneous modification of files with `use` or `import` relationships</rule>
          <rule>Coordinate changes to shared modules and macros</rule>
          <rule>Lock configuration files during individual subagent execution</rule>
          <rule>Prevent concurrent modification of style-defining modules</rule>
        </resource_protection>
        <progress_reporting>
          <requirement>Each subagent reports completion status before proceeding</requirement>
          <requirement>Real-time progress updates every 30 seconds</requirement>
          <requirement>Immediate notification of compilation failures</requirement>
        </progress_reporting>
        <consistency_validation>
          <check>Verify no cross-file style consistency breaks after each completion</check>
          <coordination>Ensure team coding standards maintained across all changes</coordination>
          <rollback>If style conflicts detected, coordinate resolution or rollback</rollback>
        </consistency_validation>
      </coordination_protocol>

      <phase_success_criteria>
        <item>All assigned subagents complete with SUCCESS, FAILURE, or PARTIAL status</item>
        <item>No compilation integrity compromised</item>
        <item>Cross-file style consistency maintained</item>
        <item>Aggregate violation reduction documented</item>
      </phase_success_criteria>
    </phase>

    <phase id="4" name="integration_validation" sequence="4">
      <description>Validate overall progress and determine iteration outcome</description>
      <steps>
        <step number="5">
          <action>Execute full codebase analysis to assess aggregate progress</action>
          <command>mix credo --strict</command>
          <metrics_collection>
            <metric name="total_violation_count">Total violations across all files</metric>
            <metric name="violation_by_severity">Breakdown by Critical, High, Normal, Low</metric>
            <metric name="violation_by_category">Breakdown by Consistency, Design, Readability, Refactor, Warning</metric>
            <metric name="violation_reduction">Baseline violations - current violations</metric>
            <metric name="new_violations">Violations that were not present in baseline</metric>
            <metric name="resolved_files">Files that now have zero violations</metric>
          </metrics_collection>
          <validation>
            <item>Credo executes successfully</item>
            <item>Metrics extracted and calculated accurately</item>
            <item>Progress measurement verified</item>
          </validation>
        </step>

        <step number="6">
          <action>Execute compilation validation to ensure code integrity</action>
          <command>mix compile</command>
          <validation>
            <item>Compilation succeeds without errors</item>
            <item>No new warnings introduced</item>
            <item>All modules load successfully</item>
          </validation>
          <error_handling>
            <condition>If compilation fails</condition>
            <response>Identify files causing compilation issues and revert problematic changes</response>
          </error_handling>
        </step>

        <step number="7">
          <action>Determine iteration outcome and next steps</action>
          <decision_tree>
            <branch condition="total_violation_count == 0">
              <outcome>SUCCESS - Mission Complete</outcome>
              <action>Log final success metrics and terminate</action>
            </branch>
            <branch condition="violation_reduction > 0 AND new_violations == 0 AND compilation_success == true">
              <outcome>PROGRESS - Continue Iteration</outcome>
              <action>Return to Phase 1 with remaining violations</action>
            </branch>
            <branch condition="violation_reduction == 0 AND iteration_count >= 3">
              <outcome>STAGNATION - Escalate to Manual Review</outcome>
              <action>Report detailed analysis of unresolved violations</action>
            </branch>
            <branch condition="new_violations > 0 OR compilation_success == false">
              <outcome>REGRESSION - Rollback and Retry</outcome>
              <action>Identify regression source and revert problematic changes</action>
            </branch>
          </decision_tree>
          <output_format>
            <field>iteration_outcome: SUCCESS/PROGRESS/STAGNATION/REGRESSION</field>
            <field>progress_metrics: before/after violation counts by severity and category</field>
            <field>compilation_status: success/failure with details</field>
            <field>next_action: specific instructions for continuation or termination</field>
            <field>unresolved_violations: detailed list if applicable</field>
          </output_format>
        </step>
      </steps>
      <phase_success_criteria>
        <item>Full Credo analysis completed successfully</item>
        <item>Compilation integrity validated</item>
        <item>Progress accurately measured and documented</item>
        <item>Clear decision made on iteration outcome</item>
      </phase_success_criteria>
    </phase>
  </execution_phases>

  <quality_gates>
    <iteration_quality>
      <gate>Each iteration must reduce total violation count</gate>
      <gate>No subagent may break compilation or introduce new violations</gate>
      <gate>All fixes must preserve code semantics and performance</gate>
      <gate>Maximum 10 iterations before escalating to manual review</gate>
      <gate>Code style changes must maintain team consistency standards</gate>
    </iteration_quality>

    <subagent_quality>
      <gate>Each subagent must validate compilation before and after changes</gate>
      <gate>Zero violation count in assigned file before marking as successful</gate>
      <gate>All modifications must preserve semantic behavior</gate>
      <gate>Subagent failure must trigger proper rollback and alternative approach</gate>
    </subagent_quality>

    <credo_specific_quality>
      <gate>Auto-fixable violations must be applied when safe and beneficial</gate>
      <gate>Design violations must be carefully evaluated for architectural impact</gate>
      <gate>Consistency violations must align with project-wide patterns</gate>
      <gate>Performance warnings must not result in runtime degradation</gate>
    </credo_specific_quality>
  </quality_gates>

  <error_handling>
    <system_level_errors>
      <error type="credo_execution_failure">
        <description>Mix credo command fails to execute</description>
        <diagnosis>Check Credo installation, .credo.exs configuration, dependency compilation</diagnosis>
        <recovery>Fix configuration issues before proceeding with violation resolution</recovery>
      </error>
      <error type="compilation_breakdown">
        <description>Code fails to compile after changes</description>
        <diagnosis>Identify syntax errors or semantic issues introduced by fixes</diagnosis>
        <recovery>Revert recent changes and apply more conservative fixes</recovery>
      </error>
    </system_level_errors>

    <iteration_level_errors>
      <error type="no_progress_detected">
        <description>Three consecutive iterations with zero violation reduction</description>
        <diagnosis>Analyze remaining violations for manual intervention requirements</diagnosis>
        <recovery>Escalate to manual review with detailed violation analysis</recovery>
      </error>
      <error type="regression_detected">
        <description>New violations introduced or compilation broken</description>
        <diagnosis>Identify specific changes that introduced regressions</diagnosis>
        <recovery>Rollback problematic changes and retry with alternative approach</recovery>
      </error>
    </iteration_level_errors>

    <subagent_level_errors>
      <error type="subagent_failure">
        <description>Subagent unable to resolve assigned file violations after 3 attempts</description>
        <diagnosis>Document specific violation patterns and attempted solutions</diagnosis>
        <recovery>Mark file for manual review and continue with other subagents</recovery>
      </error>
      <error type="style_consistency_conflict">
        <description>Subagent changes break style consistency with other files</description>
        <diagnosis>Identify conflicting style patterns and team standards</diagnosis>
        <recovery>Coordinate style resolution or rollback conflicting changes</recovery>
      </error>
    </subagent_level_errors>
  </error_handling>

  <logging_requirements>
    <iteration_logging>
      <log_entry phase="start">ITERATION {number} START: {violation_count} violations across {severity_breakdown}</log_entry>
      <log_entry phase="discovery">PHASE 1 COMPLETE: Baseline established - {violation_details}</log_entry>
      <log_entry phase="prioritization">PHASE 2 COMPLETE: {selected_count} files selected for improvement</log_entry>
      <log_entry phase="execution">PHASE 3 COMPLETE: {success_count}/{total_count} subagents successful</log_entry>
      <log_entry phase="validation">PHASE 4 COMPLETE: {outcome} - {progress_details}</log_entry>
    </iteration_logging>

    <subagent_logging>
      <format>SUBAGENT {id} STATUS: {file} - {status} - {before_violations} → {after_violations}</format>
      <required_details>
        <detail>Specific violations addressed</detail>
        <detail>Fix strategies applied</detail>
        <detail>Semantic preservation validation results</detail>
      </required_details>
    </subagent_logging>

    <credo_specific_logging>
      <format>CREDO METRICS: {severity_breakdown} | Categories: {category_breakdown} | Auto-fixable: {auto_fix_count}</format>
      <violation_tracking>
        <track>Critical violations resolved per iteration</track>
        <track>Auto-fixable vs manual violation resolution rates</track>
        <track>Category-specific improvement patterns</track>
      </violation_tracking>
    </credo_specific_logging>
  </logging_requirements>

  <execution_directive>
    Execute this systematic Credo violation resolution protocol with parallel subagent coordination, ensuring comprehensive code quality improvement while preserving functionality, performance, and team consistency standards throughout the iterative improvement process.
  </execution_directive>
</prompt>