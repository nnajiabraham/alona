# Alona

Alona is an experimental macOS-first meeting assistant inspired by Granola.ai. The goal is to provide private, local-first note taking, audio capture, and transcription for Zoom, Google Meet, and other calls without relying on cloud bots.

## Current Status
- Project scaffolding only
- PRD and implementation plans in progress

## High-Level Goals
1. Detect when a video meeting starts or when the user manually starts a recording session
2. Capture local system audio and user notes for the session
3. Transcribe the audio with NVIDIA Parakeet models hosted locally
4. Organize meeting artifacts (audio, notes, transcripts, summaries) in a user-selected directory
5. Regenerate enhanced summaries via remote or local LLMs when needed

## Contributing
This repo is currently private and under active planning. Please coordinate before opening pull requests.


curl 'https://www.veroscribe.com/api/icd-codes?query=&page=1&limit=50' \
  -H 'accept: */*' \
  -H 'accept-language: en-CA,en-GB;q=0.9,en-US;q=0.8,en;q=0.7' \
  -b '_gcl_au=1.1.446298156.1766616672; _ga=GA1.1.1155385470.1766616672; ph_phc_BvnkgFZgiyDLFTQlUkLcntXx3wlPgUsLUYTq88UafOp_posthog=%7B%22distinct_id%22%3A%22019b5290-bf3d-7e5a-b64f-b4f02d8e673e%22%2C%22%24sesid%22%3A%5B1766616776592%2C%22019b5290-bf3c-72b4-a2b6-0e57f6ef35d4%22%2C1766616776508%5D%2C%22%24initial_person_info%22%3A%7B%22r%22%3A%22https%3A%2F%2Fwww.veroscribe.com%2F%22%2C%22u%22%3A%22https%3A%2F%2Fsecure.veroscribe.com%2Fsignin%2Fsignup%22%7D%7D; _ga_J9EZH1XX14=GS2.1.s1766616671$o1$g1$t1766617799$j48$l0$h0' \
  -H 'priority: u=1, i' \
  -H 'referer: https://www.veroscribe.com/icd-10/codes' \
  -H 'sec-ch-ua: "Chromium";v="142", "Google Chrome";v="142", "Not_A Brand";v="99"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "macOS"' \
  -H 'sec-fetch-dest: empty' \
  -H 'sec-fetch-mode: cors' \
  -H 'sec-fetch-site: same-origin' \
  -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36'