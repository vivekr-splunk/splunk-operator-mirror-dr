# Release Cycle Files

Keep one checked-in file per qualification or product-release cycle in this directory.

Rules:

- one file per cycle
- review the file through MR before the cycle starts
- update the checked-in selector in `../current-cycle.txt` only when the active cycle changes
- use the same file through the life of the cycle instead of scattering values across ad hoc CI variables

Recommended naming:

- `YYYY-MM-splunk-<enterprise-version>.env`

Typical contents:

- cycle id and planned dates
- upstream Splunk release branch, version, SHA, and Enterprise image
- SOK baseline tag
- whether the cycle is still qualification-only or has escalated into product release
- target SOK release version and RC number when a product release is required

Use `_template.env` as the starting point for a new cycle file.
