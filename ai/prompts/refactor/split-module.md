<prompt>
  <role>
    <expertise>Experienced Elixir software architect specializing in module design and code organization</expertise>
    <specializations>
      <item>Identifying cohesive functional boundaries</item>
      <item>Applying Elixir naming conventions</item>
      <item>Maintaining clean module dependencies</item>
      <item>OTP application structure design</item>
      <item>Enforcing consistent module organization patterns</item>
    </specializations>
  </role>

  <task>
    <primary_objective>Analyze the provided Elixir module file and decompose it into multiple, well-organized modules following Elixir best practices and specified structure requirements</primary_objective>
    <success_criteria>
      <item>Each module has 1-3 clearly defined responsibilities (Single Responsibility Principle)</item>
      <item>No circular dependencies between new modules</item>
      <item>All modules follow Elixir naming conventions (Consistency of Naming)</item>
      <item>Module size between 100-300 lines of code</item>
      <item>Clear intent and purpose for each module (Clarity of Intent)</item>
    </success_criteria>
  </task>

  <input_requirements>
    <format>Single Elixir module file (.ex,.exs)</format>
    <file>$ARGUMENTS</file>
    <validation>
      <item>File must contain valid Elixir syntax</item>
      <item>Module must be parseable</item>
      <item>Must contain multiple logical groupings suitable for separation</item>
    </validation>
  </input_requirements>

  <module_structure_requirements>
    <organization_pattern>
      <section order="1" name="use_statements">
        <description>Any `use Module` statements</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line after group</separator>
      </section>

      <section order="2" name="import_statements">
        <description>Any `import Module` statements</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line after group</separator>
      </section>

      <section order="3" name="require_statements">
        <description>Any `require Module` statements</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line after group</separator>
      </section>

      <section order="4" name="alias_statements">
        <description>Any `alias Module` statements</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line after group</separator>
      </section>

      <section order="5" name="module_attributes">
        <description>Module attributes (example: @default_value :default)</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line after group</separator>
      </section>

      <section order="6" name="public_functions">
        <description>All public functions</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
        <separator>Empty line before private functions</separator>
      </section>

      <section order="7" name="private_functions">
        <description>All private functions</description>
        <sorting>Alphabetical order (case insensitive)</sorting>
      </section>
    </organization_pattern>
  </module_structure_requirements>

  <coding_principles>
    <clarity_of_intent>
      <requirements>
        <item>Module purpose must be immediately clear from name and @moduledoc</item>
        <item>Function names must clearly express their intent</item>
        <item>Module boundaries must reflect logical business domains</item>
        <item>Code organization follows predictable, standardized pattern</item>
      </requirements>
    </clarity_of_intent>

    <consistency_of_naming>
      <requirements>
        <item>All modules follow Elixir.CamelCase.Nested convention</item>
        <item>Function names use snake_case consistently</item>
        <item>Variable and parameter names follow snake_case</item>
        <item>Module attributes use snake_case with @ prefix</item>
        <item>Consistent terminology across related modules</item>
      </requirements>
    </consistency_of_naming>

    <single_responsibility_principle>
      <requirements>
        <item>Each module has one primary reason to change</item>
        <item>Functions within module serve the module's single purpose</item>
        <item>No mixing of unrelated concerns within a module</item>
        <item>Clear separation between data, business logic, and side effects</item>
      </requirements>
    </single_responsibility_principle>
  </coding_principles>

  <analysis_methodology>
    <functional_boundaries>
      <criteria>
        <item>Group functions by primary responsibility and data domain</item>
        <item>Identify functions that operate on the same data structures</item>
        <item>Separate pure functions from side-effect functions</item>
        <item>Group related private functions with their public interfaces</item>
        <item>Ensure each boundary aligns with Single Responsibility Principle</item>
      </criteria>
    </functional_boundaries>

    <architectural_patterns>
      <separation_strategies>
        <item>Extract distinct business domains into separate modules</item>
        <item>Separate data structures/schemas from business logic</item>
        <item>Isolate external integrations and adapters</item>
        <item>Group utility/helper functions appropriately</item>
        <item>Separate contexts from schemas in Phoenix applications</item>
      </separation_strategies>
    </architectural_patterns>

    <dependency_analysis>
      <requirements>
        <item>Map function call relationships and data flow</item>
        <item>Identify circular dependencies to avoid</item>
        <item>Determine optimal module hierarchy and imports</item>
        <item>Ensure clean separation of concerns</item>
        <item>Validate compile-time dependency order</item>
      </requirements>
    </dependency_analysis>
  </analysis_methodology>

  <output_specifications>
    <module_structure>
      <naming_convention>Elixir.CamelCase.Nested format</naming_convention>
      <required_elements>
        <item>Complete module definition with proper @moduledoc</item>
        <item>All sections organized according to specified pattern</item>
        <item>All required functions with @doc annotations</item>
        <item>@spec type definitions where applicable</item>
        <item>Appropriate use/import/require/alias statements</item>
        <item>@behaviour implementations if applicable</item>
        <item>Alphabetical ordering within each section</item>
      </required_elements>
    </module_structure>

    <file_organization>
      <filename_convention>snake_case.ex format matching module name</filename_convention>
      <directory_structure>Reflect module hierarchy within lib/ directory</directory_structure>
      <placement_guidance>Clear indication of file placement within project structure</placement_guidance>
    </file_organization>

    <refactoring_plan>
      <components>
        <item>Step-by-step migration strategy</item>
        <item>Updated import/alias statements for dependent modules</item>
        <item>Required changes to existing tests</item>
        <item>Deprecation notices for breaking changes</item>
        <item>Compilation order requirements</item>
      </components>
    </refactoring_plan>
  </output_specifications>

  <validation_criteria>
    <criterion type="compilation_success" subagent_id="compilation_validator">
      <description>All extracted modules must compile without errors</description>
      <validation_instruction>
        <role>Compilation Verification Specialist</role>
        <input>Complete refactored module files and project structure</input>
        <commands>
          <command>Execute `mix compile` for all new module files</command>
          <command>Parse compiler output for errors, warnings, and success status</command>
          <command>Verify all module dependencies resolve correctly</command>
        </commands>
        <success_criteria>
          <criterion>Zero compilation errors in output</criterion>
          <criterion>Exit code 0 from compiler</criterion>
          <criterion>All new module signatures properly declared</criterion>
          <criterion>All import/alias statements resolve successfully</criterion>
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

    <criterion type="module_structure_compliance" subagent_id="structure_validator">
      <description>All modules follow specified organization pattern exactly</description>
      <validation_instruction>
        <role>Module Structure Compliance Specialist</role>
        <input>All refactored module files with complete content</input>
        <commands>
          <command>Parse each module to identify section organization</command>
          <command>Validate alphabetical ordering within each section (case insensitive)</command>
          <command>Check proper empty line separation between sections</command>
          <command>Verify public functions before private functions</command>
        </commands>
        <success_criteria>
          <criterion>All sections present in correct order (use → import → require → alias → attributes → public → private)</criterion>
          <criterion>Alphabetical sorting within each section (case insensitive)</criterion>
          <criterion>Proper empty line separation between sections</criterion>
          <criterion>Public functions before private functions</criterion>
          <criterion>Module attributes properly declared and ordered</criterion>
        </success_criteria>
        <error_handling>
          <condition>If section ordering violations found, specify module and expected vs actual order</condition>
          <condition>If alphabetical sorting violations found, specify section and incorrect ordering</condition>
          <condition>If spacing violations found, specify missing or extra empty lines</condition>
        </error_handling>
        <output_format>
          <field>structure_compliance_status: PASS/FAIL</field>
          <field>modules_analyzed: integer</field>
          <field>section_order_violations: list of modules with incorrect section ordering</field>
          <field>alphabetical_violations: list of sections with incorrect sorting</field>
          <field>spacing_violations: list of modules with incorrect empty line usage</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="dependency_validation" subagent_id="dependency_validator">
      <description>No circular dependencies exist between new modules</description>
      <validation_instruction>
        <role>Module Dependency Analysis Specialist</role>
        <input>All refactored modules with their import/alias/require statements</input>
        <commands>
          <command>Build dependency graph from all module relationships</command>
          <command>Detect circular dependencies using graph analysis</command>
          <command>Validate compilation order feasibility</command>
          <command>Check for undefined module references</command>
        </commands>
        <success_criteria>
          <criterion>Zero circular dependencies detected</criterion>
          <criterion>All referenced modules exist or are external dependencies</criterion>
          <criterion>Clear compilation order can be established</criterion>
          <criterion>No orphaned or unreachable modules</criterion>
        </success_criteria>
        <error_handling>
          <condition>If circular dependencies found, identify specific cycle path</condition>
          <condition>If undefined references found, list missing modules</condition>
          <condition>If compilation order unclear, suggest dependency resolution</condition>
        </error_handling>
        <output_format>
          <field>dependency_status: PASS/FAIL</field>
          <field>circular_dependencies: list of dependency cycles with module paths</field>
          <field>undefined_references: list of referenced but undefined modules</field>
          <field>compilation_order: suggested order for module compilation</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="single_responsibility_validation" subagent_id="responsibility_validator">
      <description>Each module has a single, clear responsibility</description>
      <validation_instruction>
        <role>Single Responsibility Principle Analysis Specialist</role>
        <input>All refactored modules with their function definitions and @moduledoc</input>
        <commands>
          <command>Analyze @moduledoc for clear purpose statement</command>
          <command>Evaluate function cohesion within each module</command>
          <command>Identify mixed concerns or unrelated functionality</command>
          <command>Validate module size is within 100-300 line range</command>
        </commands>
        <success_criteria>
          <criterion>Each module has 1-3 clearly related responsibilities</criterion>
          <criterion>All functions within module serve the module's stated purpose</criterion>
          <criterion>No mixing of unrelated concerns (data, business logic, side effects properly separated)</criterion>
          <criterion>Module size within 100-300 lines</criterion>
          <criterion>Clear @moduledoc explaining module purpose</criterion>
        </success_criteria>
        <error_handling>
          <condition>If responsibility unclear, identify ambiguous or mixed concerns</condition>
          <condition>If module too large/small, suggest further splitting or consolidation</condition>
          <condition>If @moduledoc missing/unclear, flag documentation issues</condition>
        </error_handling>
        <output_format>
          <field>responsibility_status: PASS/FAIL</field>
          <field>modules_analyzed: integer</field>
          <field>responsibility_violations: list of modules with unclear or multiple responsibilities</field>
          <field>size_violations: list of modules outside 100-300 line range</field>
          <field>documentation_issues: list of modules with missing or unclear @moduledoc</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="naming_consistency_validation" subagent_id="naming_validator">
      <description>All naming follows Elixir conventions consistently</description>
      <validation_instruction>
        <role>Naming Convention Compliance Specialist</role>
        <input>All refactored modules with complete naming analysis</input>
        <commands>
          <command>Validate module names follow Elixir.CamelCase.Nested convention</command>
          <command>Check function names use snake_case consistently</command>
          <command>Verify variable and parameter naming consistency</command>
          <command>Validate module attribute naming (@snake_case)</command>
          <command>Check for consistent terminology across related modules</command>
        </commands>
        <success_criteria>
          <criterion>All module names follow CamelCase.Nested pattern</criterion>
          <criterion>All function names use snake_case</criterion>
          <criterion>All variables and parameters use snake_case</criterion>
          <criterion>All module attributes use @snake_case format</criterion>
          <criterion>Consistent terminology used across related modules</criterion>
          <criterion>No generic or ambiguous names (handle_stuff, do_thing, etc.)</criterion>
        </success_criteria>
        <error_handling>
          <condition>If naming violations found, specify incorrect names and suggest corrections</condition>
          <condition>If inconsistent terminology found, identify conflicts and suggest standardization</condition>
          <condition>If generic names found, suggest more specific alternatives</condition>
        </error_handling>
        <output_format>
          <field>naming_status: PASS/FAIL</field>
          <field>modules_analyzed: integer</field>
          <field>module_name_violations: list of modules with incorrect naming</field>
          <field>function_name_violations: list of functions with incorrect naming</field>
          <field>terminology_inconsistencies: list of conflicting terms across modules</field>
          <field>generic_name_violations: list of overly generic names with suggestions</field>
        </output_format>
      </validation_instruction>
    </criterion>

    <criterion type="functionality_preservation" subagent_id="functionality_validator">
      <description>All original functionality is preserved across module boundaries</description>
      <validation_instruction>
        <role>Functionality Preservation Analysis Specialist</role>
        <input>Original module and all refactored modules</input>
        <commands>
          <command>Map all original functions to their new module locations</command>
          <command>Verify all public functions remain accessible</command>
          <command>Check that private function groupings maintain original relationships</command>
          <command>Validate that no functionality is lost or duplicated</command>
        </commands>
        <success_criteria>
          <criterion>All original public functions are accessible in new structure</criterion>
          <criterion>Private function relationships preserved appropriately</criterion>
          <criterion>No functionality lost in refactoring process</criterion>
          <criterion>No duplicated functionality across modules</criterion>
          <criterion>Function signatures and return types preserved</criterion>
        </success_criteria>
        <error_handling>
          <condition>If functions missing, identify lost functionality</condition>
          <condition>If functions duplicated, identify redundant implementations</condition>
          <condition>If accessibility changed, identify breaking changes</condition>
        </error_handling>
        <output_format>
          <field>functionality_status: PASS/FAIL</field>
          <field>original_functions_count: integer</field>
          <field>preserved_functions_count: integer</field>
          <field>missing_functions: list of functions not found in new structure</field>
          <field>duplicated_functions: list of functions appearing in multiple modules</field>
          <field>accessibility_changes: list of functions with changed visibility</field>
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
      <requirement>All structural and principle requirements must be fully satisfied</requirement>
    </success_condition>

    <failure_handling>
      <condition>If any validator returns FAIL, halt and report specific issues</condition>
      <condition>Provide consolidated error report with priority-ranked fixes needed</condition>
      <condition>Structure and principle violations take highest priority in failure reporting</condition>
    </failure_handling>
  </parallel_validation_protocol>

  <output_requirements>
    <requirement id="1">Refactored Modules: Complete module files with specified organization</requirement>
    <requirement id="2">File Structure: Directory organization and placement guidance</requirement>
    <requirement id="3">Migration Guide: Step-by-step refactoring instructions</requirement>
    <requirement id="4">Dependency Updates: Required changes to imports/aliases in existing code</requirement>
    <requirement id="5">Validation Report: Consolidated results from all 6 parallel validation subagents</requirement>
    <requirement id="6">Success Confirmation: Overall PASS/FAIL status with specific issue details if failed</requirement>
  </output_requirements>

  <execution_directive>
    Execute this module refactoring systematically, followed by parallel validation using 6 specialized subagents, ensuring complete adherence to coding principles and structural requirements while preserving all functionality.
  </execution_directive>
</prompt>
