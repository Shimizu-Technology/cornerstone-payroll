# IANA top-level domains

Source: https://data.iana.org/TLD/tlds-alpha-by-domain.txt. The first line records the snapshot version and date. `Efw2Formatting` loads this file locally and matches uppercased TLDs; exports make no network request.

Refresh from the same HTTPS source before each filing season, preserve its header, and run the EFW2 generator and submitter validation specs. Review the diff before committing. `.gu` is delegated; `.guam` and `.con` are not in this snapshot.
