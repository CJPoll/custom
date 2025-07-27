<?xml version="1.0" encoding="UTF-8"?>
<refactoring_prompt>
  <header>
    <objective>Enforce Single Control-Flow Principle while preserving functionality and improving code clarity</objective>
    <target_files>$ARGUMENTS</target_files>
  </header>
  
  <parallel_processing_directive>
    <condition>When multiple files are provided as arguments</condition>
    <strategy>Process each file independently in parallel using separate subagents</strategy>
    <subagent_template>
      <role>Single Responsibility Refactoring Specialist for Single File</role>
      <instructions>Apply the complete single control-flow refactoring protocol to the assigned file</instructions>
      <input>Single file path from the provided list</input>
      <output>Complete refactored file with validation report</output>
    </subagent_template>
    <coordination>
      <instruction>Launch one subagent per file concurrently</instruction>
      <instruction>Each subagent follows the complete refactoring protocol independently</instruction>
      <instruction>Collect all subagent results before presenting final output</instruction>
    </coordination>
  </parallel_processing_directive>

  <quality_principles>
    <principle id="1">
      <name>Clarity of Intent</name>
      <description>Each function has one clear, well-named purpose</description>
    </principle>
    <principle id="2">
      <name>Consistency of Naming</name>
      <description>Function names clearly indicate their control-flow type and domain responsibility</description>
    </principle>
    <principle id="3">
      <name>Single Responsibility Principle</name>
      <description>One function, one control-flow structure, one logical concern</description>
    </principle>
  </quality_principles>

  <control_flow_definitions>
    <structure type="pipe_chains">Pipe operator sequences (|>)</structure>
    <structure type="pattern_matching">case, cond, with constructs</structure>
    <structure type="conditional_logic">if, unless, ternary operators</structure>
    <structure type="loop_constructs">for, while, each, map, etc.</structure>
    <structure type="exception_handling">try/catch, rescue blocks</structure>
    <structure type="switch_statements">Language-dependent switch constructs</structure>

    <exclusions>
      <exclusion>Function head pattern matching is permitted and not counted as control-flow nesting</exclusion>
    </exclusions>
  </control_flow_definitions>

  <constraints>
    <constraint id="1" type="multiple_control_flow_structures">
      <description>A single function must contain at most 1 control flow structure</description>
        <forbidden_patterns>
          <pattern>Nested control flow structures</pattern>
          <pattern>More than one control flow structure (even when not nested)</pattern>
        </forbidden_patterns>
        <rationale>
          Having more than one control flow structure indicates the function is
          doing too many things. This is a violation of the
          Single-Responsibility Principle
        </rationale>
    </constraint>

    <constraint id="3" type="forbidden_bare_arg_case">
      <description>Case statements cannot operate directly on bare function arguments - ALL such cases are forbidden</description>
      <forbidden_patterns>
        <pattern>case arg do ... end where arg is a function parameter</pattern>
        <pattern>def func(arg) do case arg do ... end - forbidden regardless of patterns</pattern>
      </forbidden_patterns>
      <resolution>
        <step>For :ok/:error tuple cases: trace back to caller and inline at side effect origin</step>
        <step>For non-:ok/:error cases: convert to function head pattern matching</step>
        <step>Delete functions that only handled :ok/:error patterns after inlining</step>
      </resolution>
      <rationale>Case statements on bare arguments violate idiomatic Elixir. For :ok/:error tuples, this indicates error handling separated from its source. For other patterns, function head pattern matching is clearer and more idiomatic.</rationale>
    </constraint>
  </constraints>

  <refactoring_protocol>
    <phase id="1" name="Control-Flow and Constraint Violation Detection">
      <scan_strategy>Analyze each function/method for multiple control-flow structures and constraint violations</scan_strategy>
      <violation_classification>
        <type id="A">Pipe chain + conditional (most common)</type>
        <type id="B">Nested conditionals (if inside case, etc.)</type>
        <type id="C">Loop + conditional combinations</type>
        <type id="D">Exception handling + other control-flow</type>
        <type id="E">Function head :ok/:error tuple pattern matching violation</type>
        <type id="F">Case statement on bare argument violation</type>
      </violation_classification>
      <priority_ranking>Process violations by complexity and constraint severity (constraint violations highest priority)</priority_ranking>
    </phase>

    <phase id="2" name="Function Extraction and Constraint Resolution Strategy">
      <extraction_rules>
        <rule type="pipe_chain">
          <pattern>Extract to &lt;domain&gt;_&lt;transformation_purpose&gt;(data) function</pattern>
          <requirements>
            <requirement>Preserve all intermediate transformations in sequence</requirement>
            <requirement>Maintain error propagation semantics</requirement>
          </requirements>
        </rule>

        <rule type="conditional_logic">
          <pattern>Extract to handle_&lt;condition_type&gt;(result) or process_&lt;domain_result&gt;(result)</pattern>
          <requirements>
            <requirement>Preserve all pattern matching branches</requirement>
            <requirement>Maintain error handling characteristics</requirement>
          </requirements>
        </rule>

        <rule type="loop_iteration">
          <pattern>Extract to &lt;action&gt;_&lt;collection_type&gt;(items) function</pattern>
          <requirements>
            <requirement>Preserve iteration semantics and accumulator behavior</requirement>
          </requirements>
        </rule>

        <rule type="ok_error_tuple_pattern_resolution">
          <pattern>Move :ok/:error tuple handling to the call site where the side effect occurs</pattern>
          <requirements>
            <requirement>Identify functions with :ok/:error tuple pattern heads specifically</requirement>
            <requirement>Trace back to find the caller function that produces these tuples via side effects</requirement>
            <requirement>Move :ok/:error tuple pattern matching from function heads to case statements at the call site</requirement>
            <requirement>Inline the tuple-handling function logic directly into the caller's case branches</requirement>
            <requirement>Eliminate the separate :ok/:error tuple-handling functions entirely</requirement>
            <requirement>Ensure case statements operate on function call results, not bare arguments</requirement>
            <requirement>Leave other tuple patterns (non :ok/:error) unchanged</requirement>
          </requirements>
          <resolution_strategy>
            <step>Find functions with :ok/:error tuple pattern heads (def func({:ok, data}), def func({:error, reason}))</step>
            <step>Trace back to find the caller function that produces these tuples via side effects</step>
            <step>Replace the side-effect call in caller from func(side_effect_call()) to case side_effect_call() do</step>
            <step>Move the logic from :ok/:error tuple pattern functions into the appropriate case branches</step>
            <step>Remove the now-unused :ok/:error tuple pattern functions</step>
            <step>Preserve any non :ok/:error tuple pattern functions unchanged</step>
          </resolution_strategy>
          <example>
            <before>
              def caller(data) do
                data
                |> to_request()
                |> Req.get()
                |> handle_request()
              end

              # Forbidden: :ok/:error tuple patterns
              def handle_request({:ok, resp}) do
                process_response(resp)
              end

              def handle_request({:error, resp}) do
                log_error(resp)
                {:error, :request_failed}
              end

              # Allowed: other tuple patterns
              def handle_user({:admin, user}) do
                grant_admin_access(user)
              end
            </before>
            <after>
              def caller(data) do
                request = to_request(data)

                case Req.get(request) do
                  {:ok, resp} ->
                    process_response(resp)
                  {:error, resp} ->
                    log_error(resp)
                    {:error, :request_failed}
                end
              end

              # Preserved: other tuple patterns are fine
              def handle_user({:admin, user}) do
                grant_admin_access(user)
              end
            </after>
          </example>
        </rule>

        <rule type="bare_arg_case_resolution">
          <pattern>Resolution depends on whether the bare argument case involves :ok/:error tuples</pattern>
          <requirements>
            <requirement>For :ok/:error tuple cases: trace back to caller and inline at side effect origin</requirement>
            <requirement>For non-:ok/:error cases: convert to function head pattern matching</requirement>
            <requirement>Delete intermediate functions that only handled :ok/:error tuples</requirement>
            <requirement>Preserve all case clause logic and guards</requirement>
          </requirements>
          <example>
            <title>Non-:ok/:error case - Convert to function heads</title>
            <before>
              def process(status) do
                case status do
                  :active -> handle_active()
                  :inactive -> handle_inactive()
                end
              end
            </before>
            <after>
              def process(:active), do: handle_active()
              def process(:inactive), do: handle_inactive()
            </after>
          </example>
          <example>
            <title>:ok/:error case - Inline at call site</title>
            <before>
              def handle_result(result) do
                case result do
                  {:ok, user} -> send_welcome_email(user)
                  {:error, changeset} -> log_error(changeset)
                end
              end

              def create_user(params) do
                params
                |> validate()
                |> Repo.insert()
                |> handle_result()
              end
            </before>
            <after>
              def create_user(params) do
                validated = validate(params)
                
                case Repo.insert(validated) do
                  {:ok, user} -> send_welcome_email(user)
                  {:error, changeset} -> log_error(changeset)
                end
              end
              # handle_result function deleted entirely
            </after>
          </example>
        </rule>
      </extraction_rules>
    </phase>

    <phase id="3" name="Semantic Preservation Validation">
      <critical_requirements>
        <requirement type="error_handling">All error propagation paths must remain identical</requirement>
        <requirement type="return_values">Function signatures and return types must be preserved</requirement>
        <requirement type="side_effects">Any I/O, state changes, or external calls must maintain identical behavior</requirement>
        <requirement type="performance">Avoid introducing unnecessary function call overhead in hot paths</requirement>
        <requirement type="constraint_compliance">All :ok/:error tuple pattern and bare arg case constraints must be resolved</requirement>
      </critical_requirements>
    </phase>

    <phase id="4" name="Naming Convention Enforcement">
      <naming_standards>
        <standard type="transformation_functions">&lt;verb&gt;_&lt;noun&gt; (e.g., transform_user_data, validate_input)</standard>
        <standard type="conditional_handlers">handle_&lt;condition&gt; or process_&lt;result_type&gt;</standard>
        <standard type="query_functions">&lt;noun&gt;_&lt;predicate&gt;? (e.g., user_valid?, data_complete?)</standard>
        <anti_pattern>Avoid generic names: No do_thing, handle_stuff, process_data</anti_pattern>
      </naming_standards>
    </phase>
  </refactoring_protocol>

  <example>
    <before title="Multiple Violations">
      <code language="elixir">
# Violation: Function head :ok/:error tuple pattern + nested control flow
def process_user_registration(params) do
  params
  |> validate_required_fields()
  |> normalize_email()
  |> hash_password()
  |> create_user()
  |> handle_user_creation()
end

# Forbidden: :ok/:error tuple patterns
def handle_user_creation({:ok, user}) do
  case send_welcome_email(user) do
    {:ok, _} -> {:ok, user}
    {:error, reason} -> {:error, reason}
  end
end

def handle_user_creation({:error, reason}), do: {:error, reason}

# Allowed: other tuple patterns are fine
def handle_role({:admin, user}), do: grant_admin_privileges(user)
def handle_role({:user, user}), do: set_user_permissions(user)
      </code>
    </before>

    <after title="Compliant">
      <code language="elixir">
# Compliant: :ok/:error tuple handling at call site, single control flow per function
def prepare_user_data(params) do
  params
  |> validate_required_fields()
  |> normalize_email()
  |> hash_password()
end

def process_user_registration(params) do
  user_data = prepare_user_data(params)

  case create_user(user_data) do
    {:ok, user} ->
      case send_welcome_email(user) do
        {:ok, _} -> {:ok, user}
        {:error, reason} -> {:error, reason}
      end
    {:error, reason} ->
      {:error, reason}
  end
end

# Preserved: other tuple patterns remain unchanged
def handle_role({:admin, user}), do: grant_admin_privileges(user)
def handle_role({:user, user}), do: set_user_permissions(user)
      </code>
    </after>
  </example>

  <validation_criteria>
    <criterion type="compilation_success" subagent_id="compilation_validator">
      <description>All extracted functions must compile without errors</description>
      <validation_instruction>
        <role>Compilation Verification Specialist</role>
        <input>Complete refactored file path and language environment details</input>
        <commands>
          <command>Execute compilation command for target language (e.g., `mix compile` for Elixir, `javac` for Java)</command>
          <command>Parse compiler output for errors, warnings, and success status</command>
        </commands>
        <success_criteria>
          <criterion>Zero compilation errors in output</criterion>
          <criterion>Exit code 0 from compiler</criterion>
          <criterion>All new function signatures properly declared</criterion>
        </success_criteria>
        <error_handling>
          <condition>If compilation fails, identify specific syntax errors and missing dependencies</condition>
          <condition>If warnings present, categorize as blocking vs non-blocking</condition>
        </error_handling>
        <output_format>
          <field>compilation_status: PASS/FAIL</field>
          <field>error_count: integer</field>
          <field>warning_count: integer</field>
          <field>specific_errors: list of error messages with line numbers</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="test_compatibility" subagent_id="test_validator">
      <description>Existing tests must pass without modification</description>
      <validation_instruction>
        <role>Test Compatibility Verification Specialist</role>
        <input>Original test suite and refactored code</input>
        <commands>
          <command>Execute full test suite without modifying any test files</command>
          <command>Compare test results before and after refactoring</command>
          <command>Identify any failing tests and categorize failure types</command>
        </commands>
        <success_criteria>
          <criterion>100% test pass rate maintained</criterion>
          <criterion>No new test failures introduced</criterion>
          <criterion>Test execution time within 10% of baseline</criterion>
        </success_criteria>
        <error_handling>
          <condition>If tests fail, identify which functions caused failures</condition>
          <condition>If performance degraded, flag specific slow test cases</condition>
        </error_handling>
        <output_format>
          <field>test_status: PASS/FAIL</field>
          <field>total_tests: integer</field>
          <field>passing_tests: integer</field>
          <field>failing_tests: list of test names and failure reasons</field>
          <field>performance_impact: percentage change in execution time</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="single_control_flow" subagent_id="control_flow_validator">
      <description>Each function contains exactly one control-flow structure</description>
      <validation_instruction>
        <role>Control-Flow Structure Analysis Specialist</role>
        <input>Refactored code with all function definitions</input>
        <commands>
          <command>Parse each function to identify control-flow structures</command>
          <command>Count control-flow constructs per function (pipes, case, if, loops, etc.)</command>
          <command>Validate function head pattern matching exclusion rule</command>
        </commands>
        <success_criteria>
          <criterion>Each function contains exactly 1 control-flow structure</criterion>
          <criterion>No nested control-flow violations detected</criterion>
          <criterion>Function head pattern matching properly excluded from count</criterion>
        </success_criteria>
        <error_handling>
          <condition>If violations found, specify function name and violation type</condition>
          <condition>If ambiguous cases exist, request clarification on exclusion rules</condition>
        </error_handling>
        <output_format>
          <field>control_flow_status: PASS/FAIL</field>
          <field>total_functions_analyzed: integer</field>
          <field>compliant_functions: integer</field>
          <field>violation_details: list of function names with violation types and line numbers</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="constraint_compliance" subagent_id="constraint_validator">
      <description>All additional constraints (:ok/:error tuple patterns and bare arg case) are resolved</description>
      <validation_instruction>
        <role>Additional Constraint Compliance Specialist</role>
        <input>Refactored code with all function definitions</input>
        <commands>
          <command>Scan all function heads specifically for {:ok, _} and {:error, _} pattern matching</command>
          <command>Identify case statements operating directly on function arguments</command>
          <command>Validate that :ok/:error tuple patterns only appear in case statements at side-effect call sites</command>
          <command>Verify bare argument case statements converted to function head patterns</command>
          <command>Confirm :ok/:error tuple-handling functions have been eliminated and logic moved to call sites</command>
          <command>Ensure non :ok/:error tuple patterns are preserved and unchanged</command>
        </commands>
        <success_criteria>
          <criterion>Zero function heads with :ok/:error tuple patterns specifically</criterion>
          <criterion>Zero case statements operating on bare function arguments</criterion>
          <criterion>All :ok/:error tuple handling occurs at side-effect call sites via case statements</criterion>
          <criterion>All bare arg cases converted to function head pattern matching</criterion>
          <criterion>No orphaned :ok/:error tuple-handling functions remain</criterion>
          <criterion>Non :ok/:error tuple patterns preserved unchanged</criterion>
        </success_criteria>
        <error_handling>
          <condition>If :ok/:error tuple pattern violations found, specify function name and pattern</condition>
          <condition>If bare arg case violations found, specify function and argument name</condition>
          <condition>If :ok/:error tuple handling not at call site, identify misplaced logic</condition>
          <condition>If non :ok/:error tuple patterns were incorrectly modified, flag preservation violation</condition>
        </error_handling>
        <output_format>
          <field>constraint_compliance_status: PASS/FAIL</field>
          <field>ok_error_tuple_violations: list of functions with forbidden :ok/:error tuple patterns</field>
          <field>bare_arg_case_violations: list of functions with case on bare arguments</field>
          <field>misplaced_ok_error_handling: list of functions with :ok/:error logic not at call sites</field>
          <field>incorrectly_modified_other_tuples: list of non :ok/:error tuple patterns that were changed</field>
          <field>total_constraints_checked: integer</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="function_cohesion" subagent_id="cohesion_validator">
      <description>Each extracted function has clear, single-purpose responsibility</description>
      <validation_instruction>
        <role>Function Cohesion and Responsibility Analysis Specialist</role>
        <input>List of extracted functions with their names and implementations</input>
        <commands>
          <command>Analyze function names for clarity and specificity</command>
          <command>Evaluate function implementations for single responsibility adherence</command>
          <command>Validate naming convention compliance per specified standards</command>
        </commands>
        <success_criteria>
          <criterion>All function names follow specified naming conventions</criterion>
          <criterion>Each function has one clear, identifiable responsibility</criterion>
          <criterion>No generic or ambiguous function names (do_thing, handle_stuff, etc.)</criterion>
          <criterion>Function purpose is evident from name and implementation</criterion>
        </success_criteria>
        <error_handling>
          <condition>If naming violations found, suggest specific improvements</condition>
          <condition>If responsibilities unclear, identify specific ambiguities</condition>
        </error_handling>
        <output_format>
          <field>cohesion_status: PASS/FAIL</field>
          <field>functions_analyzed: integer</field>
          <field>naming_violations: list of function names with suggested improvements</field>
          <field>responsibility_issues: list of functions with unclear purposes</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="error_propagation" subagent_id="error_flow_validator">
      <description>All error paths preserve original semantics</description>
      <validation_instruction>
        <role>Error Propagation and Semantic Preservation Specialist</role>
        <input>Original function implementations and refactored versions</input>
        <commands>
          <command>Trace all error handling paths in original vs refactored code</command>
          <command>Verify return value types and error tuple structures</command>
          <command>Validate exception handling behavior preservation</command>
          <command>Check side effect preservation in error conditions</command>
        </commands>
        <success_criteria>
          <criterion>All error return types identical between versions</criterion>
          <criterion>Error propagation paths maintain same flow</criterion>
          <criterion>Exception handling behavior unchanged</criterion>
          <criterion>Side effects in error conditions preserved</criterion>
        </success_criteria>
        <error_handling>
          <condition>If error semantics changed, identify specific deviations</condition>
          <condition>If new error paths introduced, validate they're intentional</condition>
        </error_handling>
        <output_format>
          <field>error_propagation_status: PASS/FAIL</field>
          <field>error_paths_analyzed: integer</field>
          <field>semantic_deviations: list of functions with changed error behavior</field>
          <field>side_effect_changes: list of functions with altered side effects</field>
        </output_format>
      </validation_instruction>
    </criterion>
  </validation_criteria>

  <parallel_validation_protocol>
    <coordination>
      <instruction>Execute all 6 validation subagents concurrently after refactoring completion</instruction>
      <instruction>Each subagent operates independently on the same refactored codebase</instruction>
      <instruction>Collect all validation reports before determining overall success/failure</instruction>
    </coordination>

    <success_condition>
      <requirement>ALL validation criteria must return PASS status</requirement>
      <requirement>Zero blocking errors across all validation reports</requirement>
      <requirement>All additional constraints must be fully resolved</requirement>
    </success_condition>

    <failure_handling>
      <condition>If any validator returns FAIL, halt and report specific issues</condition>
      <condition>Provide consolidated error report with priority-ranked fixes needed</condition>
      <condition>Constraint violations take highest priority in failure reporting</condition>
    </failure_handling>
  </parallel_validation_protocol>

  <output_requirements>
    <requirement id="1">Refactored Code: Complete file with all violations and constraints resolved</requirement>
    <requirement id="2">Extraction Summary: List of new functions created with their specific responsibilities</requirement>
    <requirement id="3">Constraint Resolution Report: Details of all :ok/:error tuple pattern and bare arg case fixes</requirement>
    <requirement id="4">Validation Report: Consolidated results from all 6 parallel validation subagents</requirement>
    <requirement id="5">Success Confirmation: Overall PASS/FAIL status with specific issue details if failed</requirement>
  </output_requirements>

  <execution_directive>
    When a single file is provided: Execute this refactoring systematically, followed by parallel validation using 6 specialized subagents, ensuring no functional regression while achieving perfect control-flow separation and full constraint compliance.
    
    When multiple files are provided: Execute parallel file processing using one subagent per file, where each subagent independently applies the complete refactoring protocol and validation process to its assigned file. Consolidate all results into a comprehensive report.
  </execution_directive>
</refactoring_prompt>
