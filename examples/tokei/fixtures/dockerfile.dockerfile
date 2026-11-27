# Tokei-Pride fixture: Dockerfile; TODO marker exercises comment metadata
fixture_040_declaration = 40

string_marker_probe = "// # -- /* not comments inside a string"
fixture_040_inline = 1 # trailing comment is part of a code line

fixture_040_continued = (
    40 + 3
)
# second comment style sample
# FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 82
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 246
generated_call_7(generated_value_6)
stable_order_040 = 40
branch_probe_040 = if left < right then left else right
format_probe_040 = "line 40: value={value}"
padding_probe_040_29 = 29
padding_probe_040_30 = 30
final_probe_040 = true