# Existing UD component breakdown

Derived read-only from
`runs/storage-screen-auto-20260926-forms-fixed/summary.json` by
`ud_component_breakdown.py`; no codec or timing run occurred.  The complete
machine-readable result is `manifests/ud-component-breakdown.json`.

`v4 non-payload` is `header + lexical-definition delta + framing`.  The
delta is first-use lexical spelling/text definitions; it is not merely a
model header.  The bzip3 control's `non-payload` column is only the arithmetic
grouping `total - payload`.  `payload gap + non-payload gap` equals the total
v4-minus-bzip3 gap exactly, but the grouping is not a semantic equivalence:
bzip3's payload also contains comparable spelling information.

| workload | v4 total | v4 header | v4 lexical-definition delta | v4 payload | v4 framing | v4 non-payload | bzip3 total | bzip3 payload | total gap | payload gap | non-payload gap |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Finnish FORM | 59,518 | 952 | 21,301 | 37,215 | 50 | 22,303 | 53,508 | 53,428 | 6,010 | -16,213 | 22,223 |
| Finnish prose | 59,294 | 894 | 21,176 | 37,174 | 50 | 22,120 | 53,559 | 53,479 | 5,735 | -16,305 | 22,040 |
| Turkish FORM | 26,157 | 795 | 9,155 | 16,174 | 33 | 9,983 | 22,113 | 22,049 | 4,044 | -5,875 | 9,919 |
| Turkish prose | 26,036 | 790 | 9,184 | 16,036 | 26 | 10,000 | 21,581 | 21,517 | 4,455 | -5,481 | 9,936 |
| Arabic FORM | 56,244 | 1,742 | 23,473 | 30,965 | 64 | 25,279 | 51,354 | 51,258 | 4,890 | -20,293 | 25,183 |
| Arabic prose | 59,883 | 1,705 | 28,107 | 30,006 | 65 | 29,877 | 51,516 | 51,420 | 8,367 | -21,414 | 29,781 |

The current v4 payload is smaller than bzip3 on every one of these six
workloads, but v4's charged non-payload grouping is larger by 9,919–29,781
bytes.  This identifies where the current frame bytes land; it does not prove
that v4 has a better intrinsic sequence model, because spelling information
can move between v4 delta and payload and bzip3 payload includes comparable
spelling information.  The actual v4 header bytes remain the separate values
shown in the table (for example, 952 versus 21,301 lexical-definition delta
for Finnish FORM).
