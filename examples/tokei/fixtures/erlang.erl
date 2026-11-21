% Tokei-Pride fixture: Erlang; TODO marker exercises comment metadata
fixture_031_declaration = 31

string_marker_probe = "// # -- /* not comments inside a string"
fixture_031_inline = 1 % trailing comment is part of a code line

fixture_031_continued = (
    31 + 3
)
% second comment style sample
% FIXME marker is counted once on this line

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" % this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

% generated comment row 0

generated_value_2 = 64
generated_call_3(generated_value_2)
% generated comment row 4

generated_value_6 = 192
generated_call_7(generated_value_6)
stable_order_031 = 31
branch_probe_031 = if left < right then left else right
format_probe_031 = "line 31: value={value}"
padding_probe_031_29 = 29
padding_probe_031_30 = 30
final_probe_031 = true
