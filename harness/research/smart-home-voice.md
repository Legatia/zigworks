# Smart-home voice and assistants, state of play (research notes)

Compiled 2026-11-23 for the "harness" butler (a Telegram- and terminal-first personal agent that controls the home through Home Assistant or Zigbee2MQTT, reads the car through Smartcar, runs routines and asks before risky actions).

Source tags:
- **[P]**: primary (vendor newsroom, docs, release notes).
- **[S]**: secondary (press).
- **[C]**: community (forums, GitHub).
- **[U]**: unconfirmed, conflicting, or inferred by me.
- **[OLD]**: information from before 2026 that I did not re-verify for late 2026.

Reddit could not be fetched (crawler blocked). Reddit complaints below come through press write-ups that quote it.

---

## 0. TL;DR

- Every big ecosystem now has an LLM voice assistant:
  - **Alexa+**: US GA February 2026, in 12 or more countries by November 2026.
  - **Gemini for Home**: early access since October 2025; Google Assistant on speakers ends August 2, 2027.
  - **Apple Siri AI**: beta since September 14, 2026; the HomeView hub shipped November 13, 2026.
  - **Samsung**: LLM Bixby on appliances, Korea first.
- **None of them lets an outside agent be the brain behind its speakers.** Outside services can only be tools:
  - Alexa+: MCP Toolkit and Category SDK add-ons.
  - Apple: App Intents and Shortcuts.
  - Google, Sonos, Homey and SmartThings run the other direction: outside agents can *control their devices* through MCP servers or APIs.
- **Home Assistant (HA) Assist is the only stack where a third party can be the conversation agent** behind existing voice hardware:
  - Hardware: Voice PE, ESPHome or Wyoming satellites, HA phone and watch apps.
  - Hooks: a custom `ConversationEntity`, or any OpenAI-compatible chat-completions server through the `llama_cpp` integration (2026.8).
  - HA also has an MCP server (one-click since 2026.10) and an MCP client.
  - HA can speak or ask *proactively* on satellites (`assist_satellite.announce`, `ask_question`, `start_conversation`).
- **Complaints are consistent.**
  - Generative assistants are less deterministic and slower at basic device control than the old ones. Press verdict: "neither platform reliably controls the devices it was built to manage".
  - Agentic commerce often dead-ends.
  - Apps are poor, and features are paywalled.
  - Coverage of regions and languages is patchy.
- **For a Polish or EU household the gap is stark.**
  - Alexa has no Polish, and Alexa+ is not offered in Poland.
  - Gemini for Home lists neither Poland nor Polish.
  - Siri AI is not offered on iOS in the EU and has no Polish.
- **Recommendation: complement and integrate, don't compete on in-room voice hardware.**
  - Be the household's brain through Telegram plus HA.
  - Use HA satellites as the in-room voice front-end.
  - Treat Alexa, Google and Apple speakers as remotes and announcers fed by HA.
  - Keep approvals for risky actions on the owner's phone (Telegram), not on room voice.

---

## 1. What each ecosystem ships now

### 1.1 Amazon Alexa+

**Status and price**
- **US:** Alexa+ became available to all US customers on **2026-02-04** [P/S: [TechCrunch](https://techcrunch.com/2026/02/04/alexa-amazons-ai-assistant-is-now-available-to-everyone-in-the-u-s/)].
  - Free with Prime, or **$19.99/month** standalone.
  - A limited free chat tier runs on Alexa.com and the app.
  - Runs on Echo, Fire TV, Alexa.com, the Alexa app, and partner devices (Samsung, Bose).
  - Amazon says "tens of millions" use it and opt-outs are in the "low single digits".
  - Original Alexa remains selectable, with no end date announced.
- **International**, per [Amazon's international page](https://www.aboutamazon.com/news/devices/alexa-plus-international-launch), first published 2026-03-18 and updated 2026-10-28 [P]. All are Early Access unless noted.

  | Country | Start (2026 unless noted) | Non-Prime price |
  |---|---|---|
  | Canada | 2025-11-20; full since 06-11; EN and FR | CAD 27.99/month |
  | Mexico | 01-22; first non-English launch | MXN 399/month |
  | UK | 03-19 | £19.99/month |
  | Italy | 04-15 | €22.99/month |
  | Spain | 04-23 | €22.99/month |
  | Germany and Austria | 05-07 | €22.99/month |
  | France | 05-26 | €22.99/month |
  | Brazil | 06-18 | R$99.90/month |
  | Australia | 08-06 | AU$29.99/month |
  | India | 09-16 | INR 2,000/month standalone |
  | Japan | 10-29 | ¥3,000/month |

  - Prime members get it at no extra cost. Confirmed for Germany by German press, e.g. [mobiflip](https://www.mobiflip.de/amazon-alexa-plus-deutschland/) [S].
  - Amazon plans "more than 10 additional countries in 2027".
- **Poland:** not on Amazon's list.
  - Antyweb on **2026-10-28**: "Alexa still does not officially support Polish, so commands must be given in English or another supported language" [S: [Antyweb](https://antyweb.pl/amazon-odswieza-segment-smarthome-echo-show-16-robi-wrazenie)].
  - Amazon is investing €5B in Poland for 2026–2028, but that is unrelated to Alexa [S].

**What it does**
- Natural conversation with follow-ups.
- Smart-home control, including routines created by voice.
- Calendar, lists, recipes, Q&A.
- Agentic partner tasks [P/S, TechCrunch]:
  - US partners: Uber, OpenTable, Ticketmaster, Thumbtack, Angi, Expedia, Square, Yelp, Fodor's, Suno.
  - UK partners: OpenTable, with JustEat and Treatwell planned.
  - US shopping chores (October 2026): manage subscriptions, edit lists and registries, change delivery details [S: [Engadget](https://www.engadget.com/2281378/everything-amazon-announced-october-2026-alexa-tablet-kindle-fire-tv-ring-lock/)].
- Models: built on Amazon Nova and Anthropic models, per Amazon's UK launch [S: [MacRumors](https://www.macrumors.com/2026/03/19/amazons-alexa-launches-uk-free-early-access/)].

**Devices (event of 2026-10-28)** [P: [Amazon](https://www.aboutamazon.com/news/devices/new-alexa-devices-2026)]
- Echo Dot $99.99: AZ3 chip, "built-in smart home hub", on-device "AI Accelerator" for conversation detection and noise filtering.
- Echo Studio with Home Camera $249.99: Alexa+ answers questions about what the camera sees.
- Echo Time $199.99.
- Echo Show 16 from $499.99: Alexa Home Map dashboard.
- Alexa Photo Frame.
- Alexa tablets (8, 11, 12 Pro).
- Ring Smart Lock $249, early 2027 [S: Engadget].
- The announcement does not mention which protocols the hub radio supports (Matter, Thread, Zigbee) [U].

**Privacy**
- Since **2025-03-28** all Echo voice goes to the cloud. Amazon removed "Do Not Send Voice Recordings", saying Alexa+ needs the cloud [S/OLD: [TechCrunch](https://techcrunch.com/2025/03/15/amazons-echo-will-send-all-voice-recordings-to-the-cloud-starting-march-28)].
- Pogue notes that Amazon engineers can review your Alexa+ history (with permission): "they can see your data if they want to" [S, 2026-08-03].

**Developer and third-party paths**
- **Alexa+ add-ons**, documented at [Alexa+ Developer Docs](https://developer.amazon.com/docs/alexaplus/add-ons/home) (last modified July to November 2026) [P]:
  - **Category SDK**, for pre-defined categories (restaurant reservations, food ordering, home services, local booking, ticketing, rides). It comes in two flavours: an "Action add-on" (your API behind Alexa's provider interfaces) and an "MCP add-on" that plugs into Alexa's pre-built category flows.
  - **MCP Toolkit**, for any other service. Alexa+ is the **MCP client** and calls your MCP server over **streamable HTTP**. It supports MCP spec 2025-11-25 and the MCP Apps extension for UI on screens. Your server must have "less than 500 ms" round-trip latency. Alexa+ keeps NLU, response generation and UI rendering [P: [choose-approach](https://developer.amazon.com/docs/alexaplus/add-ons/choose-the-proper-alexaplus-integration-approach.html), [MCP Toolkit overview](https://developer.amazon.com/docs/alexaplus/add-ons/mcp-toolkit-overview.html)].
  - Tooling includes the Alexa AI CLI, a local inspector, a web simulator and certification.
  - Add-ons appear to be activated by "direct named invocation" by default [P via search snippet; verify].
- **July 23, 2026 announcement** [P: [Amazon developer blog](https://developer.amazon.com/alexaplus/blogs/2026/07/alexa-plus-new-ways-to-build-experiences)]:
  - Amazon is "adopting the Model Context Protocol".
  - "Alexa+ for Builders" turns an MCP server into a simulator-ready package.
  - An AI-powered **smart home developer toolkit**, with partners Bosch, iRobot, Yale, Eufy, Tapo, Govee, Whirlpool and others.
  - Amazon Wallet checkout inside conversations.
  - "The integration paths are currently available in Preview." Countries and locales are not stated.
- The February 2025 **"Multi-Agent SDK"**, which was meant to show a partner's agent alongside Alexa [P/OLD: [blog](https://developer.amazon.com/en-US/blogs/alexa/alexa-skills-kit/2025/02/new-alexa-announce-blog)], does not appear in the current add-on docs [U].
- **Legacy skills** remain on original Alexa. Developers must apply through a form for an existing skill to be considered for "direct invocation on Alexa+".
  - Expect a curated subset. Example: Plex disabled its Alexa skill from 2026-06-15 [S/C].
  - Lowpass (2025-03-20) warned that long-tail skills would wither [S/OLD].
- There is **no Amazon consumer API or MCP server** that lets an outside agent control Alexa devices [U: nothing found].
  - In practice: put devices in HA and expose them *to* Alexa (HA Cloud/Link Smart Home skill).
  - Or use HA's **Alexa Devices** integration (since 2025.6) to make Echo speak or announce, send text commands as if spoken, and run routines. It needs Amazon login with TOTP 2FA and is unofficial and rate-limited [P: [HA docs](https://www.home-assistant.io/integrations/alexa_devices/)].

**Can a third party be the brain behind Echo? No.** You can only be an add-on or tool that Alexa+ decides to call.

### 1.2 Google: Gemini for Home (replacing Google Assistant)

**Status**
- **Early access** on speakers and displays [P: [Google Help](https://support.google.com/googlehome/answer/16618650?hl=en), read 2026-11-23]:
  - Countries now: AU, AT, BE, CA, DK, FI, FR, DE, IE, IT, JP, MX, NL, NZ, NO, ES, SE, CH, UK, US.
  - Countries "coming in December": BR, CO, IN, SG, KR, TW.
  - Languages: Danish, Dutch, English, French, German, Italian, Japanese, Norwegian, Spanish, Swedish, with Traditional Chinese, Korean and Portuguese in December.
  - **Poland and Polish are not listed.** Polish press on 2026-05-04: "Poland still isn't on the list" [S: [Antyweb](https://antyweb.pl/google-wdraza-rewolucyjne-zmiany-to-jednak-slodko-gorzkie-wiesci)]. There is also a change.org petition for Polish on Google Home speakers [C].
- **Retirement** [P: [Google Help](https://support.google.com/googlehome/answer/18957422), announced around 2026-11-20; S: [Android Authority](https://www.androidauthority.com/assistant-gemini-home-devices-3737857/), [heise](https://www.heise.de/en/news/Google-brings-Nest-devices-into-Home-app-switches-to-Gemini-11533925.html)]:
  - Google Assistant on speakers and displays will be discontinued **starting 2027-08-02**.
  - The upgrade is manual and one-way.
  - Basic Gemini for Home is free.
  - Non-upgraded devices stop responding after the shutdown.
  - The Nest app shuts on **2027-01-25**, and Nest Aware converts to Google Home Premium.
- **Hardware:** the Google Home Speaker went on sale 2026-06-25 at **$99.99**, with pre-orders in 18 countries from 06-17 [S: [Thurrott](https://thurrott.com/smart-tech/337510/googles-gemini-powered-home-speaker-launches-on-june-25-for-99-99), [9to5Google](https://9to5google.com/2026/06/17/google-home-speaker-launch/)].
- **Paywall:** Google Home Premium **Standard $10/month** and **Advanced $20/month** ($100 and $200 per year) [S: unite.ai, citing the Google Store].
  - Gemini Live ("Hey Google, let's chat") needs Premium.
  - Home Brief (daily summary) and camera history search need Advanced [P: Help page].
- **Features:**
  - Natural-language control, alarms and timers, lists, calendar, Q&A.
  - "Ask Home" for household questions, Home Brief, descriptive camera alerts [P: [I/O 2026 page](https://developers.home.google.com/io/2026)].
  - Filtering for guests and kids, Voice Match restrictions on video search [P].
  - Google says light and plug control became "1.5 seconds faster" in April 2026 [S: Android Authority/Droid Life].
  - Reliability updates in September and November 2026 [S].

**Developer and third-party paths**
- **Home APIs:** Device & Structure, Automation, Commissioning and Discovery, as **Android and iOS SDKs**. The page does not document a cloud REST API for them [P: [developers.home.google.com/apis](https://developers.home.google.com/apis)].
- **Gemini for Home as a "full-stack AI offering"**, announced at I/O on 2026-05-21, is for *service providers and hardware partners* [P: [Google Developers Blog](https://developers.googleblog.com/en/empowering-service-providers-and-hardware-partners-with-gemini-for-home)]:
  - Carriers, ISPs and security firms can bundle Premium.
  - The "Gemini built-in" hardware program has Camera and (new) **Speaker Reference Designs**. This puts *Google's* assistant in your hardware, not your brain in Google's.
- **Google Home MCP server (consumer), Early Access since 2026-09-16** [P: [docs](https://developers.home.google.com/mcp/home); S: [TechCrunch](https://techcrunch.com/2026/09/16/your-ai-agents-can-now-control-your-google-home-devices/), [unite.ai](https://unite.ai/google-opens-home-mcp-early-access-to-ai-agents-for-smart-home-control)]:
  - Endpoint `https://home.googleapis.com/mcp` (streamable HTTP), OAuth scope `home.platform.v2`.
  - Setup requires your own Google Cloud project and OAuth client. Apps in test mode must re-authenticate every 7 days.
  - Tools: `list_homes`, `list_home_resources`, `list_home_states`, `run_home_actions`, `list_home_history`, `list_automations`, `save_automation`. Press and MatterAlpha still say automations are "not supported yet", so this conflicts [U].
  - Optional familiar-faces data requires separate consent.
  - **Safety:** "prohibiting sensitive actions like unlocking doors". Rate limits apply, and latency "may be longer than expected".
  - **Requires Google Home Premium Advanced ($20/month), US, English.**
  - Example clients: Antigravity, Claude (Cowork), OpenClaw, Hermes, ChatGPT.
- A separate *developer* MCP server, `homedevelopers.googleapis.com/mcp`, only searches the docs [P].
- **Google Assistant SDK** is used by HA to send text commands and broadcast to speakers [P: [HA docs](https://www.home-assistant.io/integrations/google_assistant_sdk/)].
  - Text responses are no longer returned, room broadcasts often fail for non-English, and routines don't work.
  - Whether it keeps working after Assistant's August 2027 shutdown on speakers is **unknown** [U].
- Conversational Actions (third-party voice apps) were shut down in 2023 [OLD].

**Can a third party be the brain behind Nest speakers? No.** An outside agent can control Google Home devices through Home MCP (paid, US, no unlocking) or the mobile SDKs, but it cannot take over the speaker conversation.

### 1.3 Apple: Siri AI, Apple Home, HomeView

**Siri AI**
- Previewed at WWDC on **2026-06-08** [P: [Apple](https://apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/)].
- Released **2026-09-14** as a beta, English only [P: [Apple UK newsroom](https://www.apple.com/uk/newsroom/2026/09/siri-ai-a-profoundly-more-capable-and-personal-assistant-is-here/)].
  - French, Japanese, Korean, Portuguese and Spanish were due "next month" (October).
  - Polish press says Traditional Chinese, Norwegian, Turkish and Vietnamese come by end of 2026, **Polish not listed** [S: [gsmonline](https://gsmonline.pl/artykuly/nowa-siri-trafia-do-kolejnych-krajow-polska-wciaz-czeka), [benchmark.pl](https://www.benchmark.pl/siri-ai-nie-mowi-po-polsku-ale-apple-potwierdza-ze-prace-trwaja-7296359260497952a)].
- Features:
  - Personal context (messages, email, photos), on-screen awareness, actions in apps (WhatsApp, Audible, more "soon").
  - "Describe a shortcut" creates automations.
  - A Siri app with iCloud-synced history.
  - Models were "custom-built in collaboration with Google and its Gemini models" and run on-device and in Private Cloud Compute.
- **Not initially available in the EU on iOS, iPadOS or watchOS.** It is available on Mac and Vision Pro in the EU. It is not available in China.
- Server features have daily limits; "expanded access … for a fee in the future" [P].
- The September release's home-related items are Home app camera intelligence (descriptions, cross-camera search). These need a home hub, an Apple Intelligence iPhone and iCloud+ [P].

**Home hardware ("Welcome home" event, 2026-10-13)**
- **HomeView** [P: [Apple newsroom](https://www.apple.com/newsroom/2026/10/meet-apple-homeview-a-new-way-to-enjoy-entertainment-and-manage-the-home/)]:
  - $299, on sale **2026-11-13**.
  - Countries: AU, CA, IN, NZ, UK, US, plus SG and ZA.
  - **Not sold in the EU** ("Siri AI is currently unavailable in iOS in the EU").
  - 7-inch display, A18 chip, face recognition for **up to six people** with personal home screens.
  - Siri AI "available in beta in HomeView software version 27.2", **English only**.
  - Personal context needs a paired Apple Intelligence iPhone or iPad. Some apps need the iPhone nearby.
  - Camera and microphone processing in Secure Exclaves.
  - **No App Store**; it supports CarPlay-style audio and video apps [S: [MacRumors review](https://www.macrumors.com/2026/11/12/apple-homeview-review/)].
- **HomePod mini 2** [P: [Apple](https://apple.com/newsroom/2026/10/apple-announces-the-next-generation-of-homepod-mini)]:
  - $149, available 2026-10-30.
  - Siri AI "via a future software update", English, same regions as HomeView.
  - Recognizes **up to six users by voice**.
- A new **Apple TV 4K** with Siri AI beta was also announced. Price and dates conflict in secondary reports [U].
- **Reviews of HomeView** [S]:
  - Consumer Reports: "essentially a $300 iPhone accessory that plugs into a wall".
  - MacRumors: "not worth buying" at $299.
  - Tom's Guide: it uses an older A18 and reportedly sat in a warehouse for a year.

**Developer and third-party paths**
- **App Intents** is the way into Siri AI [P: [WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)]:
  - Entity schemas feed the Spotlight semantic index.
  - Intent schemas work with "no specific phrases".
  - New View Annotations API and App Intents Testing framework.
  - Using it requires shipping an iOS app.
- The **Foundation Models framework** now accepts "any model provider … cloud models like Claude and Gemini" through a Language Model protocol. That is for *apps*, not for Siri's brain [P].
- **"Extensions"**, letting a user pick Claude, Gemini or ChatGPT as Siri's chatbot, is widely reported (Gurman), but I could not confirm it from Apple [U].
- **HomeKit has no cloud API.**
  - HomeKit access needs the on-device framework with an entitlement. Developer ID builds can't use it, so community macOS MCP bridges exist (HomeMCPBridge, HomeClaw) [C].
  - Practical route: put devices in HA (Matter multi-admin or the HomeKit Device integration), and expose HA *to* Apple Home with HomeKit Bridge [OLD].
- **Shortcuts as a voice front-end:**
  - "Hey Siri, *shortcut name*" → Dictate text → Get Contents of URL (POST to your agent) → Speak result.
  - This has worked on iPhone, Watch, CarPlay and (via personal requests) HomePod for years [OLD; re-test on 27.x].
  - It is the only zero-App-Store way to get a self-hosted agent onto Siri, and it is phrase-triggered, not a brain replacement.

**Can a third party be the brain behind HomePod or HomeView? No.** Only App Intents or Shortcuts, plus possibly third-party chatbot "Extensions" [U].

### 1.4 Samsung SmartThings, Bixby, Galaxy AI

- **LLM-based Bixby on 2026 appliances** (Family Hub, air conditioners, washers, robot vacuums), announced **2026-03-31**, starting in South Korea [S: [Korea Times](https://www.koreatimes.co.kr/business/companies/20260331/samsung-enlists-perplexity-ai-to-refine-bixby-for-home-appliances), [SamMobile](https://www.sammobile.com/news/samsung-rolling-out-upgraded-bixby-home-appliances/)].
  - "Open Q&A" is powered by **Perplexity**, which first reached Bixby on the Galaxy S26 (One UI 8.5).
  - It handles multi-step tasks and voice-driven automations.
- **SmartThings Now** (newsroom dated 2026-10-05 or 06) [S: [SamMobile](https://sammobile.com/news/new-smartthings-app-announced-matter-1-6-support), [matter-smarthome.de](https://matter-smarthome.de/en/products/smartthings-update-matter-1-6-and-local-app-control/)]:
  - A redesigned, proactive Home tab ("right information at the right time"; for example lights and purifier on as you near home).
  - Local app-to-hub control, about 30% faster.
  - **First platform with Matter 1.6.**
  - Earlier in 2026 (April): Family Care, Pet Care, and Home Security in Now Brief, plus the robot-vacuum "Safety Patrol" [S: [TNW](https://thenextweb.com/news/samsung-smartthings-family-care-elderly-monitoring-ambient-sensing)].
- **"Agentic Home"** was found in app code: detailed daily home insights, suggested routines, and an outside agent hook including the string "ChatGPT Codex OAuth ('Agentic Home' test feature only)". It is **unannounced and may not ship** [S/U: Android Authority teardown, about November 2026, via [smarthomeassistent.de](https://www.smarthomeassistent.de/smartthings-agentic-home-ki-agenten-leak/)].
- **Developer:**
  - SmartThings REST API with an OAuth-In SmartApp. OAuth access tokens expire after 24 h and are refreshed with a refresh token.
  - **Personal access tokens have been capped at 24 h since 2024-12-30**, so long-running self-hosted integrations must use OAuth [P: [token docs](https://developer.smartthings.com/docs/service-integrations/token-management)].
  - No official Samsung MCP server was found; several community ones exist [C].
- **Third party as Bixby's brain: no.** Outside agent controlling SmartThings: yes, through the REST API with OAuth.

### 1.5 Home Assistant (Assist, Voice PE, LLM agents, MCP)

**Releases referenced**
- 2026.4 (04-01), 2026.8 (08-05), 2026.9 (09-02), 2026.10 (10-07), 2026.11 (11-04). The Cloud-to-Link rename lands in 2026.12 (12-02) [P: [HA blog index](https://www.home-assistant.io/blog/)].

**Assist pipeline**
- Wake word → STT → conversation agent → TTS.
- Runs on satellites (Voice PE, ESPHome or Wyoming devices) and the HA apps.
- **Voice Preview Edition** launched in December 2024 at $59 [P/OLD].
  - Still sold, with firmware updates through 2026 (for example 26.6.0).
  - No successor hardware announced as of 2026-11-23 [C].
- **Local first:** Speech-to-Phrase and Piper. "Prefer handling commands locally" lets the built-in intent engine take simple commands before handing off to the LLM [P/OLD]. Forum reports note routing quirks and latency outliers with it [C: [thread](https://community.home-assistant.io/t/why-prefer-handling-commands-locally-increases-the-time-from-2-5s-to-52s/947662)].
- **Proactive voice actions** [P: [assist_satellite](https://www.home-assistant.io/integrations/assist_satellite/), [Voice ch.10, 2025-06-25](https://www.home-assistant.io/blog/2025/06/25/voice-chapter-10/), [Voice ch.11, 2025-10-22](https://www.home-assistant.io/blog/2025/10/22/voice-chapter-11/)]:
  - `assist_satellite.announce` speaks a message.
  - `assist_satellite.ask_question` asks a question and returns `{id, sentence, slots}`. It matches against `answers` sentences and can run fully locally with Speech-to-Phrase.
  - `assist_satellite.start_conversation` starts a conversation from the satellite, with an `extra_system_prompt` for the agent.
- **2025.10:** up to **two wake words and pipelines per satellite**, for example a local and a cloud pipeline, or two languages.
- **Streaming TTS:** reply start time fell "from more than five seconds … to about half a second" [P: ch.11].

**LLM conversation agents**
- Official integrations: OpenAI, Google Gemini, Anthropic, Ollama, OpenRouter, and **llama.cpp (2026.8)**.
- The **llama.cpp** integration points at *any* OpenAI-compatible chat-completions server (llama.cpp, vLLM, LM Studio, DeepSeek, and others), with base URL, optional API key and model. It gives the AI "Device control" tools [P: [llama_cpp docs](https://www.home-assistant.io/integrations/llama_cpp)].
- **2026.4:** Assist shows the AI's reasoning steps and tool calls under "Show details" [S/C].
- **2026.9:** LLM tool names are now prefixed (for example `homeassistant__GetLiveContext`, `intent__HassTurnOn`). This is backward-incompatible for custom prompts.
- **2026.9:** Nabu Casa is testing a new cloud STT based on **Soniox**, aimed at accents, noise and **non-English** languages, with "no logging, storing, or training on your audio" [P: [2026.9](https://home-assistant.io/blog/2026/09/02/release-20269)].
- **Writing your own agent**, per the [ConversationEntity docs](https://contributors.home-assistant.io/core/entities/conversation/) [P]:
  - Implement `_async_handle_message(user_input, chat_log)`.
  - The input carries `text`, `conversation_id`, `device_id`, **`satellite_id`**, `language`, `agent_id`, `extra_system_prompt` and `context`.
  - Streaming goes through `async_add_delta_content_stream`.
  - `continue_conversation` is set automatically when the reply ends with "?".

**MCP server (HA as the tool provider)** [P: [mcp_server docs](https://www.home-assistant.io/integrations/mcp_server/), [2026.10 notes](https://www.home-assistant.io/blog/2026/10/07/release-202610/)]
- Since 2026.10 it is turned on in one click under Settings → System → **AI** → Model Context Protocol, with copyable URLs.
- **URLs:**
  - `/api/mcp` exposes all allowed tool sets.
  - Per-set URLs exist, for example **`/api/mcp/assist` = Device control only**, limited to entities exposed to voice assistants.
  - Every set except Device control requires an admin account. The "Home Assistant" set (all entities, logs, history, integrations) is admin-only.
- Options: "Read-only" removes state-changing tools; "Require administrator" is on by default.
- **Auth:**
  - OAuth 2.0 with PKCE plus OAuth **Client ID Metadata Documents** (client ID = the app's base URL), no client secret.
  - Clients requiring RFC 7591 Dynamic Client Registration may fail.
  - Earlier versions accepted long-lived tokens [OLD/U].
- Supports prompts, tools, and one resource, `homeassistant://assist/context-snapshot`, a plain-text snapshot of exposed entities.
- **No sampling and no notifications**, so it cannot push events.
- Named clients: Claude (web or desktop, which needs HA reachable from the internet), ChatGPT, Claude Code (HTTPS only), Codex, OpenCode, Cursor.

**MCP client (HA uses external tools)** [P: [mcp docs](https://www.home-assistant.io/integrations/mcp/)]
- Streamable HTTP with SSE fallback; stdio servers need a proxy.
- OAuth through Application Credentials.
- **Tools only**; the tool list refreshes every 30 minutes.
- Since 2026.10, installed apps that offer an MCP server are **auto-discovered**.
- Integrations add tool sets too (for example KNX in 2026.10).

**Bridges to other ecosystems**
- **Home Assistant Cloud → "Home Assistant Link"** on 2026-12-02 [P: [blog 2026-10-02](https://www.home-assistant.io/blog/2026/10/02/big-tech-ruined-the-cloud-so-were-renaming-ours/)]:
  - Remote access, Alexa and Google linking, cloud STT and TTS.
  - **€7.50/month or €75/year** [P: [Nabu Casa pricing](https://www.nabucasa.com/pricing/)].
- **Alexa Devices** integration (Echo speak, announce, text command, routines) [P].
- **Google Assistant SDK** integration (broadcast and text command) [P].

**Households**
- **2026.11:**
  - Renamed entities keep their old name as a voice alias.
  - New "People" triggers.
  - Action history records which user and cause triggered each action [P: [2026.11](https://www.home-assistant.io/blog/2026/11/04/release-202611/)].
- **2026.10:** any user can change their own profile picture.
- **"What the Heck?! 2026"** (2026-10-29) is explicitly about non-admin household members who feel "locked out of your own home" [P: [blog](https://www.home-assistant.io/blog/2026/10/29/what-the-heck-2026-everyone-at-home-gets-a-say/)].
- **No native speaker recognition** in Assist. Community add-ons exist (speaker-id, VoiceBM) [C].

**Can a third party be the brain behind HA's voice devices? YES.**
- Option 1: a custom ConversationEntity integration, which gets `satellite_id` and streaming.
- Option 2: zero HA code, by exposing an OpenAI-compatible endpoint and adding it through the llama.cpp integration. Whether `satellite_id` reaches the endpoint this way is **unclear** [U].

### 1.6 Matter

| Version | Date | Highlights |
|---|---|---|
| 1.4 | Nov 2024 | Enhanced multi-admin, energy |
| 1.4.1 | May 2025 | NFC onboarding data, multi-device QR |
| 1.4.2 | Aug 2025 | Wi-Fi-only commissioning |
| 1.5 | 2025-11-20 | Cameras, doorbells and intercoms over WebRTC; closures; soil sensors; energy tariffs; TCP |
| 1.5.1 | Mar 2026 | Multi-stream video |
| 1.6 | 2026-06-17 (CSA Unify, Austin) | Full NFC commissioning; Joint Fabric; Thermostat Suggestions; richer device status; Product Security 1.1 |

- Sources: [P: [Matter handbook](https://handbook.buildwithmatter.com/specification/), [CSA 1.6](https://csa-iot.org/newsroom/matter-1-6-enables-more-intuitive-setup-multi-ecosystem-experiences-and-context-driven-control/), [CSA 1.5](https://csa-iot.org/newsroom/matter-1-5-introduces-cameras-closures-and-enhanced-energy-management-capabilities/); S: [9to5Mac](https://9to5mac.com/2026/06/17/matter-1-6-and-product-security-1-1-officially-announced-heres-whats-new/)].
- **Joint Fabric:** several user-authorized controllers co-administer one fabric through a central datastore.
- **Thermostat Suggestions:** an ecosystem can send time-limited suggestions tied to presets, and the thermostat may decline with a reason.
- **Caveat:** "no Matter ecosystem yet synchronizes its fabric with others" [S: [matter-smarthome.de](https://matter-smarthome.de/en/development/matter-1-6-shared-fabrics-and-smarter-thermostats/)].
- Adoption: SmartThings shipped 1.6 first (October 2026). HA added Matter cameras with two-way audio (Labs) in 2026.11.
- **Relevance:** Matter is the device layer, with no voice or AI semantics. Thermostat Suggestions is a clean hook for a butler that wants to *nudge* rather than override.

### 1.7 Others

- **Sonos 27** (announced 2026-09-01) [S: [Digital Trends](https://www.digitaltrends.com/home-theater/sonos-27-is-opening-your-speakers-to-chatgpt-custom-agents-and-a-new-in-house-ai-assistant/); P: [Sonos tech blog](https://tech-blog.sonos.com/posts/sonos-27mcp/)]:
  - **"Sonos 27mcp"** (Early Access from 2026-09-07/08) at `https://mcp.ws.sonos.com/mcp`. Cloud-hosted, OAuth 2.1 with PKCE and Dynamic Client Registration, 34 tools (playback, volume, grouping, favorites), English, S2 only. ChatGPT was the first partner.
  - "Sonos 27voice" in-house assistant: opt-in early access in fall 2026.
  - **"Custom Agents"**: up to ten user-built agents with their own model, persona and voice. A tech preview, with the full product in 2027 [S/U]. This could become the first mainstream speaker that accepts a third-party brain. Watch it.
- **Homey** (Athom, 80% LG-owned since 2024):
  - **Homey Self-Hosted Server** (January 2026; Pi, Docker, NAS) [S: [FutureFive](https://futurefive.co.nz/story/homey-debuts-self-hosted-server-for-local-smart-homes)].
  - Official MCP server at `https://mcp.athom.com` with Homey-account OAuth; controls devices, Flows and Moods [P: [Homey](https://homey.app/nl-nl/news/introducing-the-homey-mcp-server/); date about 2025, U].
  - No own voice assistant.
- **Josh.ai** (high-end, dealer-installed):
  - JoshGPT (OpenAI-based) since 2023 [S/OLD].
  - "AI X OS", a redesigned app and the Josh Edge remote (shipping December 2025) [S: [CE Pro 2026-03-19](https://www.cepro.com/news/josh-ai-keynote-emphasizes-seamless-adaptive-smart-home-control-with-ai-x-os-launch/625896)].
  - Natural-language scene and automation creation at CEDIA 2026.
  - Control4 has had exclusive Josh.ai distribution since 2021 [S/OLD].
- **CEDIA 2026** [S: [CE Pro 2026-09-15](https://www.cepro.com/news/ai-on-the-cedia-expo-floor-what-the-smart-home-industry-is-actually-building/628680/)]:
  - Savant: AI assistant on panels and **push-to-talk** remotes, 56+ languages, deliberately no always-listening microphones.
  - Crestron: AI for integrators that "won't make changes without asking first".
  - Sonos was the only one with explicit MCP.
  - No Control4 AI-voice news found.

---

## 2. Integration matrix: who lets an outside agent in, and how

| Ecosystem | Outside agent as the **brain** behind existing voice devices | Outside agent as a **tool or skill** the assistant calls | Outside agent **controls the home** (agent → devices) | Outside agent **speaks or asks** on the devices |
|---|---|---|---|---|
| **Home Assistant** | **Yes.** ConversationEntity or OpenAI-compatible endpoint (llama.cpp integration); per-pipeline; "prefer local" | Yes: HA MCP client (tools only) | Yes: HA MCP server (`/api/mcp`, `/api/mcp/assist`), REST/WS API | **Yes:** `announce`, `ask_question`, `start_conversation`; TTS to media players |
| **Amazon Alexa+** | No | Yes: MCP Toolkit / Category SDK add-ons (preview, certification, <500 ms RTT, Alexa keeps NLU); legacy skills on original Alexa or curated | No official API. Unofficial: HA Alexa Devices (text command, routines) | Unofficial: HA Alexa Devices speak/announce |
| **Google Gemini for Home** | No | No general path found [U]; partner programs only | Yes (new): Home MCP (EA, US, Premium Advanced $20/month, no unlocking); Home APIs mobile SDKs | Google Assistant SDK broadcast via HA (future after 2027-08 unknown) |
| **Apple Siri / Home** | No (third-party chatbot "Extensions" unconfirmed) | App Intents (needs an iOS app); Shortcuts phrase → URL → speak [OLD pattern] | No cloud API; on-device HomeKit only, so go through HA (Matter / HomeKit Device) | Not officially [U: AirPlay TTS from HA] |
| **SmartThings / Bixby** | No | Not found [U] | Yes: REST API with OAuth-In SmartApp (PAT 24 h); "Agentic Home" in code [U] | Limited |
| **Homey** | No own voice assistant | — | Yes: official MCP (mcp.athom.com) | — |
| **Sonos** | Not yet; Custom Agents 2027 (preview) | — | Yes: Sonos 27mcp (EA, cloud) | Via HA/Sonos integrations [OLD] |
| **Josh / Control4 / Savant** | No (closed, dealer-installed) | Integrator drivers | Integrator drivers [U] | — |

**Bottom line:** only HA lets a third party sit *behind the microphone*. Everyone else lets agents be a tool, or reach devices from the outside, increasingly through vendor-hosted MCP servers that are often paywalled or region-limited.

---

## 3. What users complain about (2026)

**Reliability and determinism of basic control**
- Forkast (2026-08-21), synthesizing Consumer Reports and The Vergecast: "neither platform reliably controls the devices it was built to manage … a product category in trouble" [S: [Forkast](https://forkast.news/one-year-in-your-ai-voice-assistant-still-cant-do-its-job/)].
- **Alexa+:**
  - Pogue (2026-08-03): about half of 135 tasks right. His Ecobee could report temperature but not change it. A Sonos was labelled as a light. Alexa+ "hallucinates about itself". Calendar was "rock-solid" and Uber "amazing" [S: [Pogue](https://pogueman.substack.com/p/alexa-is-a-buggy-embarrassment)].
  - Consumer Reports: controls still buggy, and the app is slower and less usable than Apple Home, Google Home or SmartThings [S, via Forkast].
- **Gemini for Home** (Android Police, 2026-09-29) [S: [Android Police](https://www.androidpolice.com/gemini-google-home-speakers-absolute-disaster/)]:
  - Answers are slower than with Assistant.
  - "Hey Google" must be repeated 20–30% of the time.
  - It mishears ("downstairs" as "upstairs") and sometimes turns lights *on* instead of off.
  - It truncates the start of commands.
  - A custom routine fails about half the time.
  - Several speakers answer at once.
  - Other reports [S: [Android Authority](https://www.androidauthority.com/google-home-gemini-gaslighting-users-3634510/), [PiunikaWeb 2026-04-21](https://piunikaweb.com/2026/04/21/gemini-google-home-good-bad-ugly-early-user-reports/)]:
    - It refuses basic commands; users "argue with Gemini".
    - Sometimes takes more than 10 s.
    - It turns on the wrong device.
    - Reddit users say automations broke.
  - A November 2026 TechRadar headline: users are "slamming Google for not fixing 'missing and broken features'".
- **HA Assist:**
  - Wake word "not on par with the big companies" [C].
  - "Prefer handling commands locally" sometimes misroutes [C].
  - LLM latency is dominated by prompt processing and token bloat from many exposed entities [C: [community guide, August 2026](https://community.home-assistant.io/t/so-you-want-to-ai-in-home-assistant/1021777)].
  - Non-English STT is a known pain, which is why Nabu Casa is testing Soniox [P].

**Agentic promises that dead-end**
- Jen Tuohy (Vergecast, 2026-10-08) called Alexa+ "the best smart home voice assistant you can use today", but said Uber Eats orders often dead-end, grocery automation works only for Whole Foods, and Expedia is not usable. On the app: "so, so, so bad" [S: [BigGo summary](https://finance.biggo.com/news/146df4a43e7f4687)].

**Latency**
- Gemini is slower than the old Assistant [S].
- Google claims it is now 1.5 s faster on device commands (April 2026) [S].
- The Verge saw Alexa+ finish the same request in under 3 s [S via secondary].
- HA's own target is half a second to first speech with streaming TTS [P].

**Privacy**
- Alexa is cloud-only for voice since March 2025 [OLD].
- Using vendor MCP means a Google Cloud project, OAuth and Google's terms.
- Positive outliers:
  - Apple: Private Cloud Compute and Secure Exclaves.
  - HA: local-first, and Link does not log or train on audio.

**Subscriptions and paywalls**
- Alexa+: €22.99 or $19.99 for non-Prime users. German press called the price hard to justify next to ChatGPT or Gemini [S: [mydealz](https://www.mydealz.de/magazin/amazon-alexa-ist-in-deutschland-gestartet-erst-gratis-test-dann-der-preisschock-63082)].
- Google: Gemini Live and automations need Premium; Home Brief, camera search **and Home MCP** need Advanced at $20/month.
- Apple: iCloud+ for camera AI; Siri AI daily limits with "a fee in the future".

**Cross-ecosystem gaps**
- Each vendor's MCP covers only its own devices.
- Matter Joint Fabric is specified, but no ecosystem synchronizes fabrics yet.
- Alexa+ skills are curated, and the long tail is fading (for example Plex).
- Google Assistant SDK capabilities have shrunk.

**Multi-user households**
- Wrong speaker answers (Google).
- Alexa+ asks "Is that for me?" when unsure.
- HA non-admins feel "locked out", and there is no speaker ID.
- Apple is strongest: six faces on HomeView, six voices on HomePod mini 2.

**Proactivity**
- Mostly paywalled (Google Home Brief, descriptive alerts) or just starting (SmartThings Now, Alexa+ suggesting routines).
- Tuohy says proactive action is still the missing piece.

**Regional and language gaps (EU and Poland)**
- No Polish on Alexa.
- Gemini for Home has neither Poland nor Polish.
- Siri AI is not on iOS in the EU and has no Polish.
- HomeView is not sold in the EU.

### What they do well enough that a newcomer shouldn't compete

- **Far-field hardware:** mic arrays, echo cancellation, wake-word chips; good speakers and screens at $99–$299.
- **Media:** music and video services, multi-room audio, casting, Fire TV, Apple TV.
- **Reflex features:** timers, alarms, intercom and broadcast, kids profiles and filtering.
- **General Q&A and chit-chat**, now LLM-grade everywhere.
- **First-party commerce and partner deals** (Amazon Wallet, Uber or OpenTable integrations). These depend on partnerships, not code.
- **Camera AI on the vendor's own cloud:** descriptions, familiar faces, package detection, Ring.
- **On-device identity:** face and voice ID (Apple, Google, Amazon).
- **Built-in Matter, Thread or Zigbee hubs** in speakers, plus native setup flows.

---

## 4. Where an independent butler has room

1. **Proactive "notice and ask".**
   - Big-tech proactivity is paywalled, generic and siloed.
   - A butler can watch HA state (WebSocket events or automations → webhook, because the HA MCP server has no notifications), car state (Smartcar) and the calendar.
   - It then *asks* on Telegram, for example: "Garage open, everyone left 20 min ago. Close it?"
   - Low-risk nudges can go to the room with `assist_satellite.ask_question`.
2. **Cross-domain.** No assistant joins home, car, calendar, errands and money.
   - Alexa+ is limited to Amazon partners.
   - Siri AI has personal context but not in the EU and not the car (beyond CarPlay).
   - Gemini for Home is home-only, with no unlocking through MCP.
   - Example: "Leave at 7:40 for the dentist. The car is at 18% charge; pre-heat and charge now?"
3. **Approvals for risky actions as a product feature, enforced in the harness and not in prompts.**
   - Google's MCP simply *blocks* unlocking.
   - HA's MCP exposes whatever you expose to Assist.
   - The HA community guide recommends "propose then apply" and permission-layer enforcement.
   - Voice in the room is a weak approval channel: HA has no speaker ID, so anyone, or a TV, can say "yes".
   - Telegram gives a strong per-person identity, inline buttons (disabled-state buttons since Bot API 10.3), audit, timeouts, and step-up (PIN or second person).
4. **Privacy and self-hosting.**
   - Local HA control, optional local STT, and no vendor cloud or MCP paywall needed.
   - A clear story in the EU, where big-tech AI features lag.
5. **Multi-person households.**
   - Per-person Telegram identities mapped to HA persons.
   - Role-based rules for who may approve what.
   - A household group chat with **ephemeral messages** visible to one member (Bot API 10.2, 2026-07-14).
   - Satellite (room) requests treated as low-trust "household" identity.
6. **Text and phone first.**
   - Approvals, summaries, lists, photos, and anything with money or locks work better as text.
   - Voice notes on Telegram cover the "hands busy" case without new hardware.
   - In-room voice stays for quick commands and announcements.
   - **Language:** Whisper-class STT handles Polish, while the in-room big-tech assistants don't.

---

## 5. Voice input for a Telegram-first agent

### 5.1 What Telegram offers (Bot API, checked 2026-11-23) [P: [Bot API](https://core.telegram.org/bots/api), [changelog](https://core.telegram.org/bots/api-changelog)]

- **Voice notes** arrive as `message.voice`, a `Voice` object with `file_id`, `duration`, optional `mime_type` and `file_size`. The audio is OGG/Opus.
- **Download:**
  - `getFile` lets bots download files **up to 20 MB**; the link is valid for at least 1 h.
  - A self-hosted **local Bot API server** downloads with no size limit and uploads up to 2000 MB.
- **Reply with voice:**
  - `sendVoice` accepts OGG/Opus, MP3 or M4A, **up to 50 MB**.
  - When sending by URL, the file must be `audio/ogg` and 1 MB or less; 1–20 MB is sent as a file.
- **Streaming text:**
  - `sendMessageDraft` was added in 9.3 (2025-12-31) and opened to all bots in 9.5 (2026-03-01).
  - The draft is an ephemeral 30-second preview; you must finalize with `sendMessage`.
  - 10.3 (2026-08-24) added `can_stop` and `keep_on_stop`, plus `MessageGenerationStopped` updates when the user stops generation.
  - 10.1 (2026-06-11) added `sendRichMessageDraft`.
- **Approvals:** inline keyboards with callback queries. 10.3 added **disabled buttons**, useful to show "approved" or "expired".
- **Ephemeral messages in groups** (10.2, 2026-07-14) are visible only to one user and the bot. Good for per-person prompts in a family group.
- **Guest mode** (10.0, 2026-05-08): bots can receive certain messages and reply in chats they are not a member of.
- **No transcription method exists in the Bot API.** Telegram's own voice-to-text is a client and Premium feature and is not exposed to bots [U: inferred from the API].
- Bots cannot join voice calls [OLD].

### 5.2 Transcription options

Prices and benchmark numbers come from [Artificial Analysis STT](https://artificialanalysis.ai/speech-to-text) (read 2026-11-23). AA-WER and the speed factor (multiples of real time) are mostly measured on English.

| Option | Price | Speed factor | AA-WER | Polish | Notes |
|---|---|---|---|---|---|
| **Groq whisper-large-v3-turbo** | **$0.04/h** ($0.00067/min) | 216× (Groq) / 401× (AA) | 4.6% | Yes (Whisper) | **Minimum 10 s billed per request.** Accepts ogg directly. 25 MB on free tier [P: [Groq docs](https://console.groq.com/docs/speech-to-text)] |
| Groq whisper-large-v3 | $0.111/h | 189× | — | Yes | Also translates |
| **OpenAI gpt-transcribe** | $0.0045/min | 64× | 3.3% | Yes | Newer model |
| OpenAI gpt-4o-mini-transcribe | $0.003/min | 72× | 4.5% | Yes | |
| OpenAI gpt-4o-transcribe | $0.006/min | 41× | 4.0% | Yes | Also a diarize variant |
| OpenAI Whisper | $0.006/min | — | — | Yes | |
| OpenAI realtime transcription | $0.017/min | — | — | — | Realtime models [P: [pricing](https://developers.openai.com/api/docs/pricing)] |
| **Deepgram Nova-3 multilingual** | pre-recorded $0.0052/min, streaming $0.0058/min (promo) | 455× | 5.2% | **Yes** (`pl`); Flux does not support Polish | $200 free credit [P: [pricing](https://deepgram.com/pricing), [languages](https://developers.deepgram.com/docs/models-languages-overview)] |
| ElevenLabs Scribe v3 / v2 | $3.33 / $3.67 per 1000 min | 57× / 86× | 1.9% / 2.2% | Not checked [U] | Most accurate in AA |
| Mistral Voxtral Mini Transcribe | $3.0–3.5 per 1000 min | 77–103× | 2.2–3.6% | Not checked [U] | |
| Soniox v5 async | $1.66 per 1000 min | 48× | 3.8% | Not checked [U] | Engine Nabu Casa is testing for HA |
| **Local whisper.cpp** | Free (your hardware) | ~10× real time for large-v3-turbo on an M2 Pro with Metal [C] | — | Yes | On a Raspberry Pi 5, tiny runs faster than real time, base about real time, small slower [C, rough]. Convert OGG to 16 kHz WAV with ffmpeg |
| **Local NVIDIA Parakeet TDT 0.6B v3** | Free | 628× on GPU (AA via Together) | 4.5% | **Yes** (25 European languages) | 6.34% average WER on the HF Open ASR leaderboard; runs locally (NeMo, ONNX, community GGUF) [P: [HF model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)]. No per-language Polish WER found [U] |

**Typical latency for one 10–30 s voice note** (my estimates [U], from the speed factors plus network):
- Telegram `getFile` and download: about 0.1–0.3 s, since the file is only 50–150 KB.
- Groq turbo or Deepgram: about **0.3–0.8 s** end to end.
- OpenAI mini or gpt-transcribe: about **0.6–2 s**.
- Local whisper.cpp large-v3-turbo on Apple Silicon: about **1–3 s**.
- Raspberry Pi 5 with small or base models: **10–30 s**, which is too slow and too inaccurate for Polish.
- Parakeet v3 on a Mac or GPU: sub-second [U].

**Cost at personal scale:** 30 notes a day × 20 s is about 10 min/day, roughly 300 min/month.
- Groq: about $0.20/month after the 10 s minimum.
- OpenAI gpt-4o-mini-transcribe: about $0.90/month.
- gpt-transcribe: about $1.35/month.
- Deepgram: about $1.56/month.
- Local: $0.

**Cost is irrelevant. Choose on privacy, Polish accuracy and latency.**

**Suggested approach:**
1. Use a pluggable STT interface. Default to a fast cloud option (Groq turbo, or OpenAI gpt-transcribe for accuracy). Offer a **local** option (whisper.cpp large-v3-turbo or Parakeet v3) for privacy-mode households.
2. Echo the transcript ("Heard: '…'") before any approval-gated action.
3. Pass the language hint (`pl`) when known.
4. Benchmark on 20–30 real Polish and English household notes before choosing.

---

## 6. Recommendation: complement and integrate (don't compete on in-room voice)

**Stance**
- The butler is the household's *brain and conscience*: routines, cross-domain context, approvals, memory. Its primary surfaces are Telegram and the terminal.
- In-room voice is a **front-end it borrows**:
  - HA Assist satellites, where it can be the agent.
  - Big-tech speakers, which stay as remotes and announcers fed by HA.
- Don't build speakers, wake-word hardware, music, timers or general Q&A.

**Concrete integration points, in build order**

1. **HA MCP client in the harness, least privilege.**
   - Create a dedicated **non-admin** HA user and connect to **`/api/mcp/assist`** (Device control only, exposed entities only, snapshot resource).
   - For proactivity, also subscribe to HA's WebSocket events or call a harness webhook from HA automations, because MCP has no notifications.
   - Zigbee2MQTT can stay behind HA.
2. **Approval engine on Telegram.**
   - Policy lives in code, not in prompts.
   - Risky classes: locks, garage, alarm, payments, car unlock or remote start.
   - Inline buttons with disabled state after a decision, an expiry, an owner-only approver list, and an audit log.
   - Never accept a risky approval from a room satellite (no speaker ID).
3. **Telegram voice-note STT pipeline** as described in §5: getFile → STT → echo transcript → act. Optionally reply with `sendVoice` TTS and stream with `sendMessageDraft`.
4. **Harness as an HA conversation agent.** This makes Voice PE, satellites, the phone and watch apps speak to the butler.
   - Fast path: expose an OpenAI-compatible `/v1/chat/completions` and add it through HA's **llama.cpp** integration.
   - Better path: a small custom `ConversationEntity` integration that forwards `text`, `conversation_id` and `satellite_id`/`device_id`, and streams the reply.
   - Keep **"Prefer handling commands locally" on**, so lights and timers stay deterministic and instant.
5. **Proactive voice out through HA.**
   - `assist_satellite.announce` for FYIs.
   - `ask_question` for low-risk yes/no questions (the answer comes back as `id`).
   - `start_conversation` with `extra_system_prompt` to hand the room a topic.
   - For households with Echo or Nest speakers, use `notify.send_message` to the Alexa Devices "Announce" entities, or the Google Assistant SDK broadcast. Both are unofficial or fragile, and the Google path may end in 2027.
6. **Publish harness tools to HA's MCP client** (car status, calendar, errands) so HA's own agents and dashboards can query the butler. HA auto-discovers MCP servers from installed apps.
7. **Optional backends later.** Only if a user lacks HA:
   - Google Home MCP (US and Premium Advanced only).
   - SmartThings OAuth API.
   - Homey MCP.
   - Sonos MCP for music.
8. **Skip for now:**
   - An Alexa+ add-on: certification, cloud-hosted, under 500 ms, Alexa stays the brain, and not offered in Poland.
   - Google or Apple voice integrations: no brain access; Apple is only a Shortcuts phrase bridge, which could be a cheap stretch goal for iPhone users.
   - Revisit **Sonos Custom Agents** in 2027.

---

## 7. Open questions and unverified items

- Do Alexa+ MCP add-ons work in development mode on the developer's own account without certification (as old skills did)? Not found.
- Does the Google Assistant SDK broadcast keep working after Gemini for Home replaces Assistant on speakers (2027-08-02)?
- Is Apple's third-party chatbot "Extensions" for Siri real and shipped in iOS 27.x? Only reported (Gurman), not confirmed by Apple.
- Google Home MCP docs list `save_automation`, while press and MatterAlpha say automations are unsupported.
- Does the HA llama.cpp (OpenAI-compatible) path pass satellite or room identity to the endpoint? Unclear. The custom ConversationEntity path does.
- Polish WER for Parakeet v3, ElevenLabs Scribe, Voxtral and Soniox has not been measured here. Test locally.
- The Echo Dot (2026) hub radios (Matter, Thread, Zigbee) are not stated.
- Exact Apple TV 4K (2026) price and Siri AI status conflict across secondary reports.
