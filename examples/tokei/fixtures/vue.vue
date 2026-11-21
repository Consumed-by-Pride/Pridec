// Tokei-Pride fixture: Vue; TODO marker exercises comment metadata
fixture_070_declaration = 70

string_marker_probe = "// # -- /* not comments inside a string"
fixture_070_inline = 1 // trailing comment is part of a code line

fixture_070_continued = (
    70 + 3
)
<!-- TODO block begins
block continuation remains a comment
block closes here -->

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" // this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

// generated comment row 0

generated_value_2 = 142
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 426
generated_call_7(generated_value_6)
stable_order_070 = 70
branch_probe_070 = if left < right then left else right
format_probe_070 = "line 70: value={value}"
padding_probe_070_30 = 30
final_probe_070 = true