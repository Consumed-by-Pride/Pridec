# Tokei-Pride fixture: Terraform; TODO marker exercises comment metadata
fixture_050_declaration = 50

string_marker_probe = "// # -- /* not comments inside a string"
fixture_050_inline = 1 # trailing comment is part of a code line

fixture_050_continued = (
    50 + 3
)
/* TODO block begins
block continuation remains a comment
block closes here */

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 102
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 306
generated_call_7(generated_value_6)
stable_order_050 = 50
branch_probe_050 = if left < right then left else right
format_probe_050 = "line 50: value={value}"
padding_probe_050_30 = 30
final_probe_050 = true