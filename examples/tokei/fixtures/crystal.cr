# Tokei-Pride fixture: Crystal; TODO marker exercises comment metadata
fixture_045_declaration = 45

string_marker_probe = "// # -- /* not comments inside a string"
fixture_045_inline = 1 # trailing comment is part of a code line

fixture_045_continued = (
    45 + 3
)
# second comment style sample
# FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 92
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 276
generated_call_7(generated_value_6)
stable_order_045 = 45
branch_probe_045 = if left < right then left else right
format_probe_045 = "line 45: value={value}"
padding_probe_045_29 = 29
padding_probe_045_30 = 30
final_probe_045 = true
