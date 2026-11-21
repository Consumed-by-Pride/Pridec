# Tokei-Pride fixture: Starlark; TODO marker exercises comment metadata
fixture_096_declaration = 96

string_marker_probe = "// # -- /* not comments inside a string"
fixture_096_inline = 1 # trailing comment is part of a code line

fixture_096_continued = (
    96 + 3
)
# second comment style sample
# FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 194
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 582
generated_call_7(generated_value_6)
stable_order_096 = 96
branch_probe_096 = if left < right then left else right
format_probe_096 = "line 96: value={value}"
padding_probe_096_29 = 29
padding_probe_096_30 = 30
final_probe_096 = true
