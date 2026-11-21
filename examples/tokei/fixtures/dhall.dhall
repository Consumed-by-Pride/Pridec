{- TODO fixture block for Dhall -}
fixture_082_declaration = 82

string_marker_probe = "// # -- /* not comments inside a string"
fixture_082_inline = 1 {- inline note -}

fixture_082_continued = (
    82 + 3
)
{- TODO block begins
block continuation remains a comment
block closes here -}

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here"
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

generated_call_0(generated_value_-1)

generated_value_2 = 166
generated_call_3(generated_value_2)
generated_call_4(generated_value_3)

generated_value_6 = 498
generated_call_7(generated_value_6)
stable_order_082 = 82
branch_probe_082 = if left < right then left else right
format_probe_082 = "line 82: value={value}"
padding_probe_082_30 = 30
final_probe_082 = true
