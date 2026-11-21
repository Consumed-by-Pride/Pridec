# Tokei-Pride fixture: Ruby; TODO marker exercises comment metadata
fixture_010_declaration = 10

string_marker_probe = "// # -- /* not comments inside a string"
fixture_010_inline = 1 # trailing comment is part of a code line

fixture_010_continued = (
    10 + 3
)
=begin TODO block begins
block continuation remains a comment
block closes here =end

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 22
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 66
generated_call_7(generated_value_6)
stable_order_010 = 10
branch_probe_010 = if left < right then left else right
format_probe_010 = "line 10: value={value}"
padding_probe_010_30 = 30
final_probe_010 = true