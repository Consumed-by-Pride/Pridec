-- Tokei-Pride fixture: Lua; TODO marker exercises comment metadata
fixture_019_declaration = 19

string_marker_probe = "// # -- /* not comments inside a string"
fixture_019_inline = 1 -- trailing comment is part of a code line

fixture_019_continued = (
    19 + 3
)
--[[ TODO block begins
block continuation remains a comment
block closes here ]]

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" -- this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

-- generated comment row 0

generated_value_2 = 40
generated_call_3(generated_value_2)
-- generated comment row 4

generated_value_6 = 120
generated_call_7(generated_value_6)
stable_order_019 = 19
branch_probe_019 = if left < right then left else right
format_probe_019 = "line 19: value={value}"
padding_probe_019_30 = 30
final_probe_019 = true
