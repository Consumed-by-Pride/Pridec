// Tokei-Pride fixture: Pascal; TODO marker exercises comment metadata
fixture_056_declaration = 56

string_marker_probe = "// # -- /* not comments inside a string"
fixture_056_inline = 1 // trailing comment is part of a code line

fixture_056_continued = (
    56 + 3
)
(* TODO block begins
block continuation remains a comment
block closes here *)

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" // this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

// generated comment row 0

generated_value_2 = 114
generated_call_3(generated_value_2)
// generated comment row 4

generated_value_6 = 342
generated_call_7(generated_value_6)
stable_order_056 = 56
branch_probe_056 = if left < right then left else right
format_probe_056 = "line 56: value={value}"
padding_probe_056_30 = 30
final_probe_056 = true
