# Code style (`.editorconfig`)

The server formats and auto-imports with IntelliJ's own code style engine, and there are **no LSP settings for it**
(see [Formatting](features.md#formatting)). The only way to configure it is `.editorconfig`, using the `ij_*` properties
exactly like the IDE. This is what controls, among other things, when an auto-import collapses into `import java.util.*;`.

Everything below was extracted from the bundled server, build `263.6379.0` (`plugins/java/lib/intellij.java.frontback.impl.jar`).
Re-extract it after a server update, see [Listing the properties yourself](#listing-the-properties-yourself).

## Where the server reads it

- `.editorconfig` files apply to their directory and everything below it. The closest file wins and options from other
  files are merged in. `root = true` stops the search upwards.
- Anything not set in an `.editorconfig` falls back to the server's default code style, which is IntelliJ's default.
- A file in a parent directory of your projects (for example `~/Sources/.editorconfig`) is picked up for all of them,
  which is the way to keep personal preferences out of the repositories.
- Language specific `ij_java_*` / `ij_kotlin_*` options override the common `ij_any_*` and generic `ij_*` ones for the same
  property.
- Live template indentation (`sout`, `fori`, ...) ignores it, see [Live template indentation fix](features.md#live-template-indentation-fix).

JetBrains documents the mechanism, not the full property list: the [EditorConfig help page](https://www.jetbrains.com/help/idea/editorconfig.html)
says each property has a code style scheme option with a similar name. The IDE can also export your code style scheme to an
`.editorconfig` (on the *Settings | Editor | Code Style* page), which writes the properties your IDE version supports.

## Common recipes

### Never collapse imports into `*`

IntelliJ collapses imports into `import java.util.*;` once a package reaches 5 classes (3 for static imports). Raise
both thresholds to keep explicit imports, which is also what Sonar rule `java:S2208` asks for:

```ini
[*.java]
ij_java_class_count_to_use_import_on_demand = 999
ij_java_names_count_to_use_import_on_demand = 999
```

For Kotlin: `ij_kotlin_name_count_to_use_star_import` and `ij_kotlin_name_count_to_use_star_import_for_members`.

### Import order and blank lines

```ini
[*.java]
# `*` all other imports, `|` blank line, `$*` all static imports
ij_java_imports_layout = *,|,javax.**,java.**,|,$*
ij_java_layout_static_imports_separately = true
ij_java_blank_lines_after_imports = 1
ij_java_use_single_class_imports = true
```

### Line length and indentation

```ini
[*.{java,kt}]
max_line_length = 120
indent_style = space
indent_size = 4
ij_continuation_indent_size = 8
```

## Property names

A property is `ij_<language>_<setting>` where `<setting>` is the lower case name of the field in IntelliJ's
`CodeStyleSettings` classes. Java has two sets of them:

1. **Java only** (`JavaCodeStyleSettings`): 92 settings, imports, naming prefixes, annotations, javadoc.
2. **Shared with other languages** (`CommonCodeStyleSettings`): 182 settings, blank lines, braces, spacing, wrapping,
   alignment. For these, `ij_any_<setting>` sets it for every language and `ij_java_<setting>` for Java only.

Types: `boolean` is `true`/`false`, `int` is a number (wrapping, brace style and similar are enum constants stored as numbers,
which is why exporting from the IDE is the easiest way to get the values), `string` is free text and `table` is a list
(`ij_java_imports_layout`, `ij_java_packages_to_use_import_on_demand`; IDE exports show their format).

Defaults and descriptions are not part of this list. They are the IDE defaults, and every property has the same name as
its checkbox in *Settings | Editor | Code Style | Java*.

### Java only

```ini
ij_java_field_name_prefix                                     # string
ij_java_static_field_name_prefix                              # string
ij_java_parameter_name_prefix                                 # string
ij_java_local_variable_name_prefix                            # string
ij_java_test_name_prefix                                      # string
ij_java_subclass_name_prefix                                  # string
ij_java_field_name_suffix                                     # string
ij_java_static_field_name_suffix                              # string
ij_java_parameter_name_suffix                                 # string
ij_java_local_variable_name_suffix                            # string
ij_java_test_name_suffix                                      # string
ij_java_subclass_name_suffix                                  # string
ij_java_prefer_longer_names                                   # boolean
ij_java_generate_final_locals                                 # boolean
ij_java_generate_final_parameters                             # boolean
ij_java_visibility                                            # string
ij_java_use_external_annotations                              # boolean
ij_java_generate_use_type_annotation_before_type              # boolean
ij_java_insert_override_annotation                            # boolean
ij_java_repeat_synchronized                                   # boolean
ij_java_replace_instanceof                                    # boolean
ij_java_replace_cast                                          # boolean
ij_java_replace_instanceof_and_cast                           # boolean
ij_java_replace_null_check                                    # boolean
ij_java_replace_sum                                           # boolean
ij_java_spaces_within_angle_brackets                          # boolean
ij_java_space_after_closing_angle_bracket_in_type_argument    # boolean
ij_java_space_before_opening_angle_bracket_in_type_parameter  # boolean
ij_java_space_around_type_bounds_in_type_parameters           # boolean
ij_java_do_not_wrap_after_single_annotation                   # boolean
ij_java_do_not_wrap_after_single_annotation_in_parameter      # boolean
ij_java_annotation_new_line_in_record_component               # boolean
ij_java_annotation_parameter_wrap                             # int
ij_java_enum_field_annotation_wrap                            # int
ij_java_align_multiline_annotation_parameters                 # boolean
ij_java_new_line_after_lparen_in_annotation                   # boolean
ij_java_rparen_on_new_line_in_annotation                      # boolean
ij_java_space_around_annotation_eq                            # boolean
ij_java_align_multiline_text_blocks                           # boolean
ij_java_blank_lines_around_initializer                        # int
ij_java_blank_lines_around_field_with_annotations             # int
ij_java_blank_lines_between_record_components                 # int
ij_java_class_names_in_javadoc                                # int
ij_java_space_before_colon_in_foreach                         # boolean
ij_java_strip_whitespace_from_blank_lines_in_text_blocks      # boolean
ij_java_space_inside_one_line_enum_braces                     # boolean
ij_java_spaces_inside_block_braces_when_body_is_present       # boolean
ij_java_new_line_when_body_is_presented                       # boolean
ij_java_layout_static_imports_separately                      # boolean
ij_java_layout_on_demand_import_from_same_package_first       # boolean
ij_java_preserve_module_imports                               # boolean
ij_java_delete_unused_module_imports                          # boolean
ij_java_keep_blank_lines_between_imports                      # boolean
ij_java_use_fq_class_names                                    # boolean
ij_java_use_single_class_imports                              # boolean
ij_java_insert_inner_class_imports                            # boolean
ij_java_class_count_to_use_import_on_demand                   # int
ij_java_names_count_to_use_import_on_demand                   # int
ij_java_packages_to_use_import_on_demand                      # table
ij_java_import_layout_table                                   # table
ij_java_wrap_semicolon_after_call_chain                       # boolean
ij_java_record_components_wrap                                # int
ij_java_align_multiline_records                               # boolean
ij_java_new_line_after_lparen_in_record_header                # boolean
ij_java_rparen_on_new_line_in_record_header                   # boolean
ij_java_space_within_record_header                            # boolean
ij_java_deconstruction_list_wrap                              # int
ij_java_align_multiline_deconstruction_list_components        # boolean
ij_java_new_line_after_lparen_in_deconstruction_pattern       # boolean
ij_java_rparen_on_new_line_in_deconstruction_pattern          # boolean
ij_java_space_within_deconstruction_list                      # boolean
ij_java_space_before_deconstruction_list                      # boolean
ij_java_multi_catch_types_wrap                                # int
ij_java_align_types_in_multi_catch                            # boolean
ij_java_enable_javadoc_formatting                             # boolean
ij_java_jd_align_param_comments                               # boolean
ij_java_jd_align_exception_comments                           # boolean
ij_java_jd_add_blank_after_parm_comments                      # boolean
ij_java_jd_add_blank_after_return                             # boolean
ij_java_jd_add_blank_after_description                        # boolean
ij_java_jd_p_at_empty_lines                                   # boolean
ij_java_jd_keep_invalid_tags                                  # boolean
ij_java_jd_keep_empty_lines                                   # boolean
ij_java_jd_do_not_wrap_one_line_comments                      # boolean
ij_java_jd_use_throws_not_exception                           # boolean
ij_java_jd_keep_empty_parameter                               # boolean
ij_java_jd_keep_empty_exception                               # boolean
ij_java_jd_keep_empty_return                                  # boolean
ij_java_jd_leading_asterisks_are_enabled                      # boolean
ij_java_jd_preserve_line_feeds                                # boolean
ij_java_jd_param_description_on_new_line                      # boolean
ij_java_jd_indent_on_continuation                             # boolean
```

### Shared (use as `ij_java_*` or `ij_any_*`)

```ini
ij_java_right_margin                                             # int
ij_java_line_comment_at_first_column                             # boolean
ij_java_block_comment_at_first_column                            # boolean
ij_java_line_comment_add_space                                   # boolean
ij_java_block_comment_add_space                                  # boolean
ij_java_line_comment_add_space_on_reformat                       # boolean
ij_java_line_comment_add_space_in_suppression                    # boolean
ij_java_documentation_line_comment_preferred                     # boolean
ij_java_keep_line_breaks                                         # boolean
ij_java_keep_first_column_comment                                # boolean
ij_java_keep_control_statement_in_one_line                       # boolean
ij_java_keep_blank_lines_in_declarations                         # int
ij_java_keep_blank_lines_in_code                                 # int
ij_java_keep_blank_lines_between_package_declaration_and_header  # int
ij_java_keep_blank_lines_before_rbrace                           # int
ij_java_blank_lines_before_package                               # int
ij_java_blank_lines_after_package                                # int
ij_java_blank_lines_before_imports                               # int
ij_java_blank_lines_after_imports                                # int
ij_java_blank_lines_around_class                                 # int
ij_java_blank_lines_around_field                                 # int
ij_java_blank_lines_around_method                                # int
ij_java_blank_lines_before_method_body                           # int
ij_java_blank_lines_around_field_in_interface                    # int
ij_java_blank_lines_around_method_in_interface                   # int
ij_java_blank_lines_after_class_header                           # int
ij_java_blank_lines_after_anonymous_class_header                 # int
ij_java_blank_lines_before_class_end                             # int
ij_java_brace_style                                              # int
ij_java_class_brace_style                                        # int
ij_java_method_brace_style                                       # int
ij_java_lambda_brace_style                                       # int
ij_java_do_not_indent_top_level_class_members                    # boolean
ij_java_else_on_new_line                                         # boolean
ij_java_while_on_new_line                                        # boolean
ij_java_catch_on_new_line                                        # boolean
ij_java_finally_on_new_line                                      # boolean
ij_java_indent_case_from_switch                                  # boolean
ij_java_case_statement_on_new_line                               # boolean
ij_java_indent_break_from_case                                   # boolean
ij_java_special_else_if_treatment                                # boolean
ij_java_align_multiline_chained_methods                          # boolean
ij_java_align_multiline_parameters                               # boolean
ij_java_align_multiline_parameters_in_calls                      # boolean
ij_java_align_multiline_resources                                # boolean
ij_java_align_multiline_for                                      # boolean
ij_java_align_multiline_binary_operation                         # boolean
ij_java_align_multiline_assignment                               # boolean
ij_java_align_multiline_ternary_operation                        # boolean
ij_java_align_multiline_throws_list                              # boolean
ij_java_align_throws_keyword                                     # boolean
ij_java_align_multiline_extends_list                             # boolean
ij_java_align_multiline_method_brackets                          # boolean
ij_java_align_multiline_parenthesized_expression                 # boolean
ij_java_align_multiline_array_initializer_expression             # boolean
ij_java_align_group_field_declarations                           # boolean
ij_java_align_consecutive_variable_declarations                  # boolean
ij_java_align_consecutive_assignments                            # boolean
ij_java_align_subsequent_simple_methods                          # boolean
ij_java_space_around_assignment_operators                        # boolean
ij_java_space_around_logical_operators                           # boolean
ij_java_space_around_equality_operators                          # boolean
ij_java_space_around_relational_operators                        # boolean
ij_java_space_around_bitwise_operators                           # boolean
ij_java_space_around_additive_operators                          # boolean
ij_java_space_around_multiplicative_operators                    # boolean
ij_java_space_around_shift_operators                             # boolean
ij_java_space_around_unary_operator                              # boolean
ij_java_space_around_lambda_arrow                                # boolean
ij_java_space_around_method_ref_dbl_colon                        # boolean
ij_java_space_after_comma                                        # boolean
ij_java_space_after_comma_in_type_arguments                      # boolean
ij_java_space_before_comma                                       # boolean
ij_java_space_after_semicolon                                    # boolean
ij_java_space_before_semicolon                                   # boolean
ij_java_space_within_parentheses                                 # boolean
ij_java_space_within_method_call_parentheses                     # boolean
ij_java_space_within_empty_method_call_parentheses               # boolean
ij_java_space_within_method_parentheses                          # boolean
ij_java_space_within_empty_method_parentheses                    # boolean
ij_java_space_within_if_parentheses                              # boolean
ij_java_space_within_while_parentheses                           # boolean
ij_java_space_within_for_parentheses                             # boolean
ij_java_space_within_try_parentheses                             # boolean
ij_java_space_within_catch_parentheses                           # boolean
ij_java_space_within_switch_parentheses                          # boolean
ij_java_space_within_synchronized_parentheses                    # boolean
ij_java_space_within_cast_parentheses                            # boolean
ij_java_space_within_brackets                                    # boolean
ij_java_space_within_braces                                      # boolean
ij_java_space_within_array_initializer_braces                    # boolean
ij_java_space_within_empty_array_initializer_braces              # boolean
ij_java_space_after_type_cast                                    # boolean
ij_java_space_before_method_call_parentheses                     # boolean
ij_java_space_before_method_parentheses                          # boolean
ij_java_space_before_if_parentheses                              # boolean
ij_java_space_before_while_parentheses                           # boolean
ij_java_space_before_for_parentheses                             # boolean
ij_java_space_before_try_parentheses                             # boolean
ij_java_space_before_catch_parentheses                           # boolean
ij_java_space_before_switch_parentheses                          # boolean
ij_java_space_before_synchronized_parentheses                    # boolean
ij_java_space_before_class_lbrace                                # boolean
ij_java_space_before_method_lbrace                               # boolean
ij_java_space_before_if_lbrace                                   # boolean
ij_java_space_before_else_lbrace                                 # boolean
ij_java_space_before_while_lbrace                                # boolean
ij_java_space_before_for_lbrace                                  # boolean
ij_java_space_before_do_lbrace                                   # boolean
ij_java_space_before_switch_lbrace                               # boolean
ij_java_space_before_try_lbrace                                  # boolean
ij_java_space_before_catch_lbrace                                # boolean
ij_java_space_before_finally_lbrace                              # boolean
ij_java_space_before_synchronized_lbrace                         # boolean
ij_java_space_before_array_initializer_lbrace                    # boolean
ij_java_space_before_annotation_array_initializer_lbrace         # boolean
ij_java_space_before_else_keyword                                # boolean
ij_java_space_before_while_keyword                               # boolean
ij_java_space_before_catch_keyword                               # boolean
ij_java_space_before_finally_keyword                             # boolean
ij_java_space_before_quest                                       # boolean
ij_java_space_after_quest                                        # boolean
ij_java_space_before_colon                                       # boolean
ij_java_space_after_colon                                        # boolean
ij_java_space_before_type_parameter_list                         # boolean
ij_java_call_parameters_wrap                                     # int
ij_java_prefer_parameters_wrap                                   # boolean
ij_java_call_parameters_lparen_on_next_line                      # boolean
ij_java_call_parameters_rparen_on_next_line                      # boolean
ij_java_method_parameters_wrap                                   # int
ij_java_method_parameters_lparen_on_next_line                    # boolean
ij_java_method_parameters_rparen_on_next_line                    # boolean
ij_java_resource_list_wrap                                       # int
ij_java_resource_list_lparen_on_next_line                        # boolean
ij_java_resource_list_rparen_on_next_line                        # boolean
ij_java_extends_list_wrap                                        # int
ij_java_throws_list_wrap                                         # int
ij_java_extends_keyword_wrap                                     # int
ij_java_throws_keyword_wrap                                      # int
ij_java_method_call_chain_wrap                                   # int
ij_java_wrap_first_method_in_call_chain                          # boolean
ij_java_parentheses_expression_lparen_wrap                       # boolean
ij_java_parentheses_expression_rparen_wrap                       # boolean
ij_java_binary_operation_wrap                                    # int
ij_java_binary_operation_sign_on_next_line                       # boolean
ij_java_ternary_operation_wrap                                   # int
ij_java_ternary_operation_signs_on_next_line                     # boolean
ij_java_modifier_list_wrap                                       # boolean
ij_java_keep_simple_blocks_in_one_line                           # boolean
ij_java_keep_simple_methods_in_one_line                          # boolean
ij_java_keep_simple_lambdas_in_one_line                          # boolean
ij_java_keep_simple_classes_in_one_line                          # boolean
ij_java_keep_multiple_expressions_in_one_line                    # boolean
ij_java_for_statement_wrap                                       # int
ij_java_for_statement_lparen_on_next_line                        # boolean
ij_java_for_statement_rparen_on_next_line                        # boolean
ij_java_array_initializer_wrap                                   # int
ij_java_array_initializer_lbrace_on_next_line                    # boolean
ij_java_array_initializer_rbrace_on_next_line                    # boolean
ij_java_assignment_wrap                                          # int
ij_java_place_assignment_sign_on_next_line                       # boolean
ij_java_wrap_comments                                            # boolean
ij_java_assert_statement_wrap                                    # int
ij_java_switch_expressions_wrap                                  # int
ij_java_assert_statement_colon_on_next_line                      # boolean
ij_java_if_brace_force                                           # int
ij_java_dowhile_brace_force                                      # int
ij_java_while_brace_force                                        # int
ij_java_for_brace_force                                          # int
ij_java_wrap_long_lines                                          # boolean
ij_java_method_annotation_wrap                                   # int
ij_java_class_annotation_wrap                                    # int
ij_java_field_annotation_wrap                                    # int
ij_java_parameter_annotation_wrap                                # int
ij_java_variable_annotation_wrap                                 # int
ij_java_space_before_anotation_parameter_list                    # boolean
ij_java_space_within_annotation_parentheses                      # boolean
ij_java_enum_constants_wrap                                      # int
ij_java_builder_methods                                          # string
ij_java_keep_builder_methods_indents                             # boolean
ij_java_force_rearrange_mode                                     # int
ij_java_wrap_on_typing                                           # int
```

### Kotlin only

51 settings (`KotlinCodeStyleSettings`). Kotlin also uses the shared list above, as `ij_kotlin_*`.

```ini
ij_kotlin_packages_to_use_star_imports                                                # table
ij_kotlin_packages_import_layout                                                      # table
ij_kotlin_space_around_elvis                                                          # boolean
ij_kotlin_space_around_range                                                          # boolean
ij_kotlin_space_before_type_colon                                                     # boolean
ij_kotlin_space_after_type_colon                                                      # boolean
ij_kotlin_space_before_extend_colon                                                   # boolean
ij_kotlin_space_after_extend_colon                                                    # boolean
ij_kotlin_insert_whitespaces_in_simple_one_line_method                                # boolean
ij_kotlin_align_in_columns_case_branch                                                # boolean
ij_kotlin_line_break_after_multiline_when_entry                                       # boolean
ij_kotlin_indent_before_arrow_on_new_line                                             # boolean
ij_kotlin_space_around_function_type_arrow                                            # boolean
ij_kotlin_space_around_when_arrow                                                     # boolean
ij_kotlin_space_before_lambda_arrow                                                   # boolean
ij_kotlin_space_before_when_parentheses                                               # boolean
ij_kotlin_space_after_context_parameter_list_in_function_type                         # boolean
ij_kotlin_lbrace_on_next_line                                                         # boolean
ij_kotlin_enable_kdoc_formatting                                                      # boolean
ij_kotlin_kdoc_preserve_line_feeds                                                    # boolean
ij_kotlin_name_count_to_use_star_import                                               # int
ij_kotlin_name_count_to_use_star_import_for_members                                   # int
ij_kotlin_import_nested_classes                                                       # boolean
ij_kotlin_continuation_indent_in_parameter_lists                                      # boolean
ij_kotlin_continuation_indent_in_context_parameter_lists                              # boolean
ij_kotlin_continuation_indent_in_argument_lists                                       # boolean
ij_kotlin_continuation_indent_for_expression_bodies                                   # boolean
ij_kotlin_continuation_indent_for_chained_calls                                       # boolean
ij_kotlin_continuation_indent_in_supertype_lists                                      # boolean
ij_kotlin_continuation_indent_in_if_conditions                                        # boolean
ij_kotlin_continuation_indent_in_elvis                                                # boolean
ij_kotlin_blank_lines_around_block_when_branches                                      # int
ij_kotlin_wrap_expression_body_functions                                              # int
ij_kotlin_wrap_elvis_expressions                                                      # int
ij_kotlin_property_context_parameters_wrap                                            # int
ij_kotlin_function_context_parameters_wrap                                            # int
ij_kotlin_if_rparen_on_new_line                                                       # boolean
ij_kotlin_allow_trailing_comma                                                        # boolean
ij_kotlin_allow_trailing_comma_on_call_site                                           # boolean
ij_kotlin_allow_trailing_comma_type_parameter_list                                    # boolean
ij_kotlin_allow_trailing_comma_destructuring_declaration                              # boolean
ij_kotlin_allow_trailing_comma_when_entry                                             # boolean
ij_kotlin_allow_trailing_comma_function_literal                                       # boolean
ij_kotlin_allow_trailing_comma_value_parameter_list                                   # boolean
ij_kotlin_allow_trailing_comma_context_receiver_list                                  # boolean
ij_kotlin_allow_trailing_comma_collection_literal_expression                          # boolean
ij_kotlin_allow_trailing_comma_type_argument_list                                     # boolean
ij_kotlin_allow_trailing_comma_indices                                                # boolean
ij_kotlin_allow_trailing_comma_value_argument_list                                    # boolean
ij_kotlin_blank_lines_before_declaration_with_comment_or_annotation_on_separate_line  # int
ij_kotlin_code_style_defaults                                                         # string
```

## Listing the properties yourself

The lists above are generated from the server jar with `javap`, a JDK tool:

```sh
SERVER=~/.local/share/nvim/intellij-server/server
CP=$(find "$SERVER/lib" "$SERVER/plugins/java" -name '*.jar' | tr '\n' ':')

# Java only
javap -cp "$CP" -public com.intellij.psi.codeStyle.JavaCodeStyleSettings
# Shared
javap -cp "$CP" -public com.intellij.psi.codeStyle.CommonCodeStyleSettings
```

Every non-static `public` field is a property. Kotlin's are in `org.jetbrains.kotlin.idea.core.formatter.KotlinCodeStyleSettings`
(jar `plugins/kotlin/lib/intellij.kotlin.formatter.minimal.jar`) and share the same `CommonCodeStyleSettings`.
