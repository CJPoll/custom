<?xml version="1.0" encoding="UTF-8"?>
<function_naming_refactor_prompt>
 <header>
   <objective>Enforce function naming conventions that distinguish side-effect functions from pure functions</objective>
   <target_files>$ARGUMENTS</target_files>
 </header>
 
 <parallel_processing_directive>
   <condition>When multiple files are provided as arguments</condition>
   <strategy>Process each file independently in parallel using separate subagents</strategy>
   <subagent_template>
     <role>Function Naming Refactoring Specialist for Single File</role>
     <instructions>Apply the complete function naming refactoring protocol to the assigned file</instructions>
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
     <description>Function names immediately communicate whether they have side effects or are pure transformations</description>
   </principle>
   <principle id="2">
     <name>Consistency of Naming</name>
     <description>Imperative names reserved exclusively for side-effect functions; descriptive names for pure functions</description>
   </principle>
   <principle id="3">
     <name>Single Responsibility Principle</name>
     <description>Each function has one clear purpose reflected in its naming pattern</description>
   </principle>
 </quality_principles>

 <naming_constraints>
   <constraint type="side_effect_functions">
     <description>Functions with side effects (CRUD, I/O, state mutations) may use imperative names but are not required to</description>
     <allowed_patterns>
       <pattern>get_* (database queries, API calls)</pattern>
       <pattern>list_* (collection retrieval operations)</pattern>
       <pattern>create_* (entity creation with persistence)</pattern>
       <pattern>update_* (entity modification with persistence)</pattern>
       <pattern>delete_* (entity removal with persistence)</pattern>
       <pattern>save_* (persistence operations)</pattern>
       <pattern>send_* (external communication)</pattern>
       <pattern>write_* (file/stream operations)</pattern>
       <pattern>log_* (logging operations)</pattern>
     </allowed_patterns>
     <side_effect_examples>
       <example>Database interactions (SELECT, INSERT, UPDATE, DELETE)</example>
       <example>File system operations (read, write, delete files)</example>
       <example>Network requests (HTTP calls, API interactions)</example>
       <example>Global state mutations (updating caches, session data)</example>
       <example>External service calls (email sending, payment processing)</example>
       <example>Logging and monitoring operations</example>
     </side_effect_examples>
   </constraint>

   <constraint type="pure_functions">
     <description>Functions without side effects MUST NOT use imperative names; named after what they return</description>
     <naming_patterns>
       <pattern>transformed_* (data transformation results)</pattern>
       <pattern>validated_* (validation results)</pattern>
       <pattern>filtered_* (filtered collections)</pattern>
       <pattern>sorted_* (sorted collections)</pattern>
       <pattern>formatted_* (formatting results)</pattern>
       <pattern>parsed_* (parsing results)</pattern>
       <pattern>*_valid? (boolean predicates)</pattern>
       <pattern>*_present? (existence checks)</pattern>
       <pattern>*_count (counting operations)</pattern>
       <pattern>*_sum (aggregation results)</pattern>
     </naming_patterns>
     <forbidden_patterns>
       <pattern>get_* (implies retrieval side effect)</pattern>
       <pattern>set_* (implies mutation side effect)</pattern>
       <pattern>create_* (implies creation side effect)</pattern>
       <pattern>update_* (implies modification side effect)</pattern>
       <pattern>process_* (too vague, doesn't describe return value)</pattern>
       <pattern>handle_* (too vague, doesn't describe return value)</pattern>
       <pattern>do_* (too vague, doesn't describe return value)</pattern>
     </forbidden_patterns>
   </constraint>
 </naming_constraints>

 <refactoring_protocol>
   <phase id="1" name="Function Classification">
     <scan_strategy>Analyze each function to determine if it has side effects</scan_strategy>
     <classification_criteria>
       <side_effect_indicators>
         <indicator>Database queries or mutations (SQL, ORM calls)</indicator>
         <indicator>File system operations (File.read, File.write, etc.)</indicator>
         <indicator>Network requests (HTTP.get, API.call, etc.)</indicator>
         <indicator>Global state mutations (Agent.update, GenServer.call, etc.)</indicator>
         <indicator>External service calls (Mailer.send, Payment.process, etc.)</indicator>
         <indicator>Logging operations (Logger.info, etc.)</indicator>
         <indicator>Random number generation</indicator>
         <indicator>Current timestamp retrieval</indicator>
       </side_effect_indicators>
       <pure_function_indicators>
         <indicator>Data transformations using pure functions</indicator>
         <indicator>Calculations and computations</indicator>
         <indicator>String/data formatting</indicator>
         <indicator>Validation logic</indicator>
         <indicator>Filtering and sorting operations</indicator>
         <indicator>Pattern matching and parsing</indicator>
       </pure_function_indicators>
     </classification_criteria>
   </phase>

   <phase id="2" name="Naming Violation Detection">
     <violation_types>
       <violation type="impure_imperative">
         <description>Pure function using imperative naming pattern</description>
         <example>get_user_age/1 that only calculates age from birthdate</example>
       </violation>
       <violation type="side_effect_unclear">
         <description>Side-effect function using unclear naming that doesn't indicate the side effect</description>
         <example>user_from_database/1 could be clearer as get_user/1, but descriptive names are also acceptable</example>
       </violation>
       <violation type="vague_naming">
         <description>Function name doesn't clearly indicate return value or side effect</description>
         <example>process_data/1, handle_request/1, do_thing/1</example>
       </violation>
     </violation_types>
   </phase>

   <phase id="3" name="Rename Strategy Application">
     <rename_rules>
       <rule type="pure_to_descriptive">
         <condition>Pure function with imperative name</condition>
         <strategy>Rename to describe the transformation or return value</strategy>
         <examples>
           <example>get_full_name/1 → full_name/1 or formatted_full_name/1</example>
           <example>calculate_age/1 → user_age/1 or age_in_years/1</example>
           <example>validate_email/1 → email_valid?/1 or validated_email/1</example>
         </examples>
       </rule>

       <rule type="side_effect_clarity">
         <condition>Side-effect function with unclear naming</condition>
         <strategy>Use clear naming that indicates the side effect (imperative or descriptive)</strategy>
         <examples>
           <example>user_from_database/1 → get_user/1 (imperative) or fetch_user/1 (imperative) or user_by_id/1 (descriptive)</example>
           <example>persist_changes/1 → save_user/1 (imperative) or store_user/1 (imperative)</example>
           <example>email_notification/1 → send_notification/1 (imperative) or deliver_email/1 (imperative)</example>
         </examples>
       </rule>

       <rule type="vague_to_specific">
         <condition>Function with generic or unclear name</condition>
         <strategy>Use specific name reflecting actual operation</strategy>
         <examples>
           <example>process_data/1 → validated_user_data/1 (if pure)</example>
           <example>handle_request/1 → create_user/1 (if side effect)</example>
         </examples>
       </rule>
     </rename_rules>
   </phase>

   <phase id="4" name="Reference Update">
     <update_strategy>
       <requirement>Update all function calls to use new names</requirement>
       <requirement>Update documentation and comments referencing old names</requirement>
       <requirement>Update test function names and assertions</requirement>
       <requirement>Update module exports and imports</requirement>
     </update_strategy>
   </phase>
 </refactoring_protocol>

 <examples>
   <before title="Naming Violations">
     <code language="elixir">
# Violation: Pure function with imperative name
def get_full_name(user) do
 "#{user.first_name} #{user.last_name}"
end

# Violation: Side-effect function with unclear name
def user_from_database(id) do
 Repo.get(User, id)
end

# Violation: Vague naming
def process_user_data(data) do
 data
 |> validate_required_fields()
 |> normalize_email()
end
     </code>
   </before>

   <after title="Compliant Naming">
     <code language="elixir">
# Correct: Pure function named after return value
def full_name(user) do
 "#{user.first_name} #{user.last_name}"
end

# Correct: Side-effect function with clear name (imperative style)
def get_user(id) do
 Repo.get(User, id)
end

# Also correct: Side-effect function with clear name (descriptive style)
def user_by_id(id) do
 Repo.get(User, id)
end

# Correct: Pure function named after transformation
def validated_user_data(data) do
 data
 |> validate_required_fields()
 |> normalize_email()
end
     </code>
   </after>
 </examples>

 <validation_criteria>
   <criterion type="compilation_success" subagent_id="compilation_validator">
     <description>All renamed functions and their references compile without errors</description>
     <validation_instruction>
       <role>Compilation and Reference Verification Specialist</role>
       <input>Complete refactored file with all function renames and reference updates</input>
       <commands>
         <command>Execute compilation command for target language</command>
         <command>Parse compiler output for undefined function errors</command>
         <command>Verify all function references have been updated</command>
       </commands>
       <success_criteria>
         <criterion>Zero compilation errors</criterion>
         <criterion>No undefined function references</criterion>
         <criterion>All module exports/imports updated correctly</criterion>
       </success_criteria>
       <error_handling>
         <condition>If undefined function errors found, identify missed references</condition>
         <condition>If compilation fails, categorize error types (syntax vs reference)</condition>
       </error_handling>
       <output_format>
         <field>compilation_status: PASS/FAIL</field>
         <field>undefined_functions: list of missing function references</field>
         <field>syntax_errors: list of syntax issues introduced</field>
       </output_format>
     </validation_instruction>
   </criterion>

   <criterion type="naming_convention_compliance" subagent_id="naming_validator">
     <description>All functions follow correct naming conventions for their side-effect classification</description>
     <validation_instruction>
       <role>Function Naming Convention Analysis Specialist</role>
       <input>Complete list of functions with their implementations and side-effect classifications</input>
       <commands>
         <command>Classify each function as pure or side-effect based on implementation</command>
         <command>Validate naming pattern compliance for each classification</command>
         <command>Check for forbidden imperative patterns in pure functions</command>
         <command>Verify descriptive naming for pure functions</command>
       </commands>
       <success_criteria>
         <criterion>All side-effect functions use clear naming that indicates the side effect (imperative or descriptive patterns acceptable)</criterion>
         <criterion>All pure functions use descriptive naming patterns</criterion>
         <criterion>No forbidden naming patterns detected</criterion>
         <criterion>Function names clearly indicate return values or side effects</criterion>
       </success_criteria>
       <error_handling>
         <condition>If naming violations found, specify function name and violation type</condition>
         <condition>If classification unclear, request implementation analysis</condition>
       </error_handling>
       <output_format>
         <field>naming_compliance_status: PASS/FAIL</field>
         <field>total_functions_analyzed: integer</field>
         <field>pure_functions_compliant: integer</field>
         <field>side_effect_functions_compliant: integer</field>
         <field>naming_violations: list with function names, current names, and suggested corrections</field>
       </output_format>
     </validation_instruction>
   </criterion>

   <criterion type="side_effect_classification" subagent_id="classification_validator">
     <description>Functions are correctly classified as pure or side-effect based on their implementations</description>
     <validation_instruction>
       <role>Side-Effect Analysis and Classification Specialist</role>
       <input>Function implementations with their current classifications</input>
       <commands>
         <command>Analyze each function implementation for side-effect indicators</command>
         <command>Verify classification accuracy against implementation</command>
         <command>Check for hidden side effects (logging, random generation, time-dependent operations)</command>
       </commands>
       <success_criteria>
         <criterion>All side-effect functions correctly identified</criterion>
         <criterion>All pure functions verified as side-effect free</criterion>
         <criterion>No misclassified functions detected</criterion>
       </success_criteria>
       <error_handling>
         <condition>If misclassification found, provide correct classification with justification</condition>
         <condition>If ambiguous cases exist, flag for manual review</condition>
       </error_handling>
       <output_format>
         <field>classification_status: PASS/FAIL</field>
         <field>correctly_classified: integer</field>
         <field>misclassified_functions: list with function names and correct classifications</field>
         <field>ambiguous_cases: list of functions requiring manual review</field>
       </output_format>
     </validation_instruction>
   </criterion>

   <criterion type="test_compatibility" subagent_id="test_validator">
     <description>All tests continue to pass with updated function names</description>
     <validation_instruction>
       <role>Test Suite Compatibility Verification Specialist</role>
       <input>Test files and refactored code with renamed functions</input>
       <commands>
         <command>Execute full test suite</command>
         <command>Verify all test function calls use updated names</command>
         <command>Check test documentation and comments for accuracy</command>
       </commands>
       <success_criteria>
         <criterion>100% test pass rate maintained</criterion>
         <criterion>All test function calls updated to new names</criterion>
         <criterion>Test documentation reflects new function names</criterion>
       </success_criteria>
       <error_handling>
         <condition>If tests fail, identify which renamed functions caused failures</condition>
         <condition>If test names outdated, flag for update</condition>
       </error_handling>
       <output_format>
         <field>test_status: PASS/FAIL</field>
         <field>total_tests: integer</field>
         <field>failing_tests: list of test names and failure reasons</field>
         <field>outdated_test_references: list of tests with old function names</field>
       </output_format>
     </validation_instruction>
   </criterion>

   <criterion type="semantic_preservation" subagent_id="semantic_validator">
     <description>Function behavior and return values remain identical after renaming</description>
     <validation_instruction>
       <role>Semantic Equivalence Verification Specialist</role>
       <input>Original and refactored function implementations</input>
       <commands>
         <command>Compare function implementations before and after renaming</command>
         <command>Verify only names changed, not logic or behavior</command>
         <command>Check return types and error handling preservation</command>
       </commands>
       <success_criteria>
         <criterion>All function implementations identical except for names</criterion>
         <criterion>Return types and values unchanged</criterion>
         <criterion>Error handling behavior preserved</criterion>
       </success_criteria>
       <error_handling>
         <condition>If implementation changes detected, flag as unintended modification</condition>
         <condition>If behavior changes found, specify exact differences</condition>
       </error_handling>
       <output_format>
         <field>semantic_preservation_status: PASS/FAIL</field>
         <field>functions_compared: integer</field>
         <field>unintended_changes: list of functions with implementation modifications</field>
         <field>behavior_differences: list of functions with changed behavior</field>
       </output_format>
     </validation_instruction>
   </criterion>
 </validation_criteria>

 <parallel_validation_protocol>
   <coordination>
     <instruction>Execute all 5 validation subagents concurrently after renaming completion</instruction>
     <instruction>Each subagent operates independently on the same refactored codebase</instruction>
     <instruction>Collect all validation reports before determining overall success/failure</instruction>
   </coordination>

   <success_condition>
     <requirement>ALL validation criteria must return PASS status</requirement>
     <requirement>Zero blocking errors across all validation reports</requirement>
   </success_condition>

   <failure_handling>
     <condition>If any validator returns FAIL, halt and report specific issues</condition>
     <condition>Provide consolidated error report with priority-ranked fixes needed</condition>
   </failure_handling>
 </parallel_validation_protocol>

 <output_requirements>
   <requirement id="1">Refactored Code: Complete file with all function names updated</requirement>
   <requirement id="2">Rename Summary: List of all function renames with before/after names and classifications</requirement>
   <requirement id="3">Validation Report: Consolidated results from all 5 parallel validation subagents</requirement>
   <requirement id="4">Success Confirmation: Overall PASS/FAIL status with specific issue details if failed</requirement>
 </output_requirements>

 <execution_directive>
   When a single file is provided: Execute this function naming refactoring systematically, followed by parallel validation using 5 specialized subagents, ensuring semantic preservation while achieving perfect naming convention compliance.
   
   When multiple files are provided: Execute parallel file processing using one subagent per file, where each subagent independently applies the complete refactoring protocol and validation process to its assigned file. Consolidate all results into a comprehensive report.
 </execution_directive>
</function_naming_refactor_prompt>
