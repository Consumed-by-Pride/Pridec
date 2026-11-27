# Tokei-Pride fixture: Perl; TODO marker exercises comment metadata
fixture_013_declaration = 13

string_marker_probe = "// # -- /* not comments inside a string"
fixture_013_inline = 1 # trailing comment is part of a code line

fixture_013_continued = (
    13 + 3
)
=pod TODO block begins
block continuation remains a comment
block closes here =cut

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 28
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 84
generated_call_7(generated_value_6)
stable_order_013 = 13
branch_probe_013 = if left < right then left else right
format_probe_013 = "line 13: value={value}"
padding_probe_013_30 = 30
final_probe_013 = true
