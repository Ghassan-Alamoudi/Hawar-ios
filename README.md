# Sard (personal)

iPhone broadcast extension that reads English game subtitles from the screen,
translates them to Arabic, and sends them to the Samsung TV app (SardTest) via Supabase Realtime.

Build: GitHub Actions -> "Build IPA" -> download the `Sard-ipa` artifact, then sign and install.

Secrets needed: `SUPABASE_URL`, `SUPABASE_KEY`, optional `GOOGLE_KEY`.
