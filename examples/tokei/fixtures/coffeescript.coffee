# Tokei-Pride fixture: CoffeeScript; TODO marker exercises comment metadata
fixture_077_declaration = 77

string_marker_probe = "// # -- /* not comments inside a string"
fixture_077_inline = 1 # trailing comment is part of a code line

fixture_077_continued = (
    77 + 3
)
### TODO block begins
block continuation remains a comment
block closes here ###

array_probe = [1, 2, 3, 5, 8, 13]
operator_probe = left + right * factor
quoted_hash_probe = "# is data here" # this is a comment
unicode_probe = "λ bar μ mu tilde"
empty_record_probe = {}

# generated comment row 0

generated_value_2 = 156
generated_call_3(generated_value_2)
# generated comment row 4

generated_value_6 = 468
generated_call_7(generated_value_6)
stable_order_077 = 77
branch_probe_077 = if left < right then left else right
format_probe_077 = "line 77: value={value}"
padding_probe_077_30 = 30
final_probe_077 = true
