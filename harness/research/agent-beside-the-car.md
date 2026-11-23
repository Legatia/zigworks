# Run your agent beside the car, not inside it

*Updated 22 Nov 2026: the Zig implementation notes are rewritten for Zig 0.17.1, the version the zigworks tools use, and their code is in [`cantap/`](cantap/), built and run on 0.17.1 (what was tested is at the end of that section). A new section before the conclusion, [What was built from this](#what-was-built-from-this-22-nov-2026), covers canmcp and carcloud and corrects four points about Smartcar. The rest of the research is as it was. Its counterpart for the home is [`agent-in-the-home.md`](agent-in-the-home.md).*

Yes, you can run your own Zig agent harness "on" an electric vehicle in late 2026, but not on the car's own computers. **No mainstream EV offers a sanctioned way to run native Linux binaries on its factory head unit**, and no OEM AI assistant accepts third-party tools. What does work is an agent that controls the car through official cloud APIs, and a separate Linux box in the cabin that reads the CAN bus through SocketCAN. That box is where your process, socket, systemd and SocketCAN skills pay off. The practical stack is a Zig binary on a Raspberry Pi 5, Jetson or comma four. It reads broadcast CAN through a **hardware-silent tap**, optionally polls manufacturer battery data while parked, and sends a small allowlist of comfort and charging commands through Tesla's Fleet API or an aggregator such as Smartcar. The dividing line, technically and legally, is reading versus writing. EU law gives you a right to your car's data, including raw CAN messages, but no right to its functions. Anything that writes to vehicle buses is unapproved under type-approval rules, is blocked by gateways on most newer cars, and is the same technique thieves use. Polish law tolerates a passive, voice-first box that changes no registration data. It offers no route at all for home-made steering, braking or acceleration control. Treat everything below as engineering information, not legal advice.

## The factory computers are closed, so the agent lives next to them

The factory head unit is the obvious place to run code, and it is the one place you can't. Android Automotive cars (Polestar, Volvo, GM, Renault and others) accept only sandboxed Android apps in fixed categories: media, navigation, points of interest, IoT, weather, parked-only video and games, and a labs-only browser ([Android for Cars](https://developer.android.com/training/cars)). A sandboxed app cannot manage processes, open SocketCAN or touch systemd. Polestar's developer page offers an emulator image but describes no vehicle-data API or developer mode ([Polestar developer](https://www.polestar.com/se/developer)). Tesla's AMD infotainment computer runs **Linux 5.4** with a separate FreeRTOS gateway. The only public root, by TU Berlin researchers at Black Hat 2023, needed voltage-glitching the AMD Secure Processor with a Teensy wired to the board. It was **not persistent**, so it had to be repeated every boot, and root on the infotainment still could not change signed gateway configuration ([Werling et al., Black Hat 2023](https://i.blackhat.com/BH-US-23/Presentations/US-23-Werling-Jailbreaking-Teslas.pdf)). Tesla's sanctioned alternative is a "research-registered vehicle" for security researchers. Even there, Tesla warns that "any damage to the car resulting from any software modifications will not be covered" ([Tesla Product Security](https://www.tesla.com/legal/security)). Rooting your daily driver's main screen, which also controls core vehicle functions, is a research project, not a deployment platform.

The OEMs' own LLM assistants confirm the pattern. Tesla Grok reached all of Europe with the Summer 2026 update and handles navigation, calls, music and climate ([Not a Tesla App](https://www.notateslaapp.com/news/4473/tesla-is-expanding-grok-to-all-of-europe-and-more-of-asia)). Gemini began rolling out to existing Google built-in cars in June 2026, starting with Volvo, and can set A/C, heated seats and wipers ([9to5Google](https://9to5google.com/2026/06/26/gemini-begins-rolling-out-for-existing-android-automotive-vehicles/)). BMW added Alexa+ technology for the iX3 from H2 2026 ([BMW Group](https://newsroom.bmwgroup.com/emea/a-milestone-for-human-vehicle-interaction-bmw-intelligent-personal-assistant-expanded-to-include-amazon-alexa--technology)), and Mercedes' CLA assistant uses ChatGPT-4o ([InsideEVs](https://insideevs.com/news/782831/mercedes-cla-ai-assistant-review/)). None of the sources describes a third-party plugin or tool API. The nearest opening is Apple's iOS 26.4 CarPlay category for voice AI apps such as ChatGPT and Claude. Those apps "cannot control vehicle or iPhone functions" ([MacRumors](https://www.macrumors.com/2026/02/18/ios-26-4-carplay-support/)). The useful lesson is what OEMs themselves let an LLM touch: climate, seats, navigation, media, calls and the glovebox. Driving functions stay withheld. That is a ready-made allowlist for your own harness.

## Cloud APIs already give an agent sanctioned eyes and a few hands

The lowest-risk way to give an agent real vehicle control needs no hardware at all. **Tesla's Fleet API is the most complete official third-party API of any OEM**, and it fits a hobby budget. Tesla's billing page grants a **$10 monthly discount** for individual developers. Its own worked examples price a stream-optimised consumer app at **$0.026** against $0.852 for a polling one, and estimate polling `vehicle_data` at about $0.12 per car per hour ([Tesla Billing & Limits](https://developer.tesla.com/docs/fleet-api/billing-and-limits)). Per-vehicle rate limits are 60 requests/min for realtime and cached data, **3 wakes/min**, and 30 commands/min, shared across all apps on the account ([same source](https://developer.tesla.com/docs/fleet-api/billing-and-limits)). On 2026-11-11 Tesla added `vehicle_data_cached`, which returns the last reported data **without waking the car**, plus service-history endpoints ([Tesla announcements](https://developer.tesla.com/docs/fleet-api/announcements)). Commands must be signed end to end. The only official implementation is the Go `vehicle-command` package. It includes `tesla-http-proxy`, which turns REST calls into signed commands, and `tesla-control`, a CLI that also sends commands locally over **BLE on Linux** at no cloud cost. The owner authorises your key by opening `tesla.com/_ak/<your_domain>` in the Tesla app ([teslamotors/vehicle-command](https://github.com/teslamotors/vehicle-command)).

For other brands sold in Poland, the routes are thinner. **Smartcar's free tier covers one real vehicle** for individuals. Paid plans start at $1.99 per vehicle per month with 100 commands per month, and Poland is an officially supported country ([Smartcar pricing](https://smartcar.com/es/pricing); [Smartcar EU](https://smartcar.com:443/product/compatible-vehicles/eu)). In April 2026 Smartcar announced an OEM-direct integration with VW Group (VW, Škoda, SEAT, CUPRA, Audi) covering state of charge and remote charge start, stop and scheduling ([Smartcar blog](https://smartcar.com/blog/smartcar-integrates-with-volkswagen-group-info-services-ag-across-europe)). BMW opened CarData to private EU users in September 2025 as a Data Act response. It offers MQTT streaming of 244 selectable metrics and REST capped at 50 calls/day, and users report it is read-only ([bimmer_connected #745](https://github.com/bimmerconnected/bimmer_connected/discussions/745)). Mercedes' official Fleet APIs, including remote charge start and stop, target fleets and partners ([Mercedes-Benz Connectivity](https://connectivity.mercedes-benz.com/news/new-data-packages-for-streamlined-odometer-recordings-charging-insights-and-remote-management)). Hyundai/Kia relies on the unofficial `kia_uvo` library. In the EU it supports lock, climate, charge control and charge limits, but its maintainer no longer owns a car and is seeking replacements ([kia_uvo](https://github.com/Hyundai-Kia-Connect/kia_uvo)). Smartcar's per-brand matrix for Hyundai/Kia, Renault, BYD and MG was not checked, so treat coverage for those brands as unverified.

| Route | Reads | Commands | Cost for one car | Fit for a Zig harness |
|---|---|---|---|---|
| Tesla Fleet API + Telemetry | Rich; cached endpoint avoids waking the car | Yes, signed via Go proxy | Within $10/month credit if streaming | Excellent; run `tesla-http-proxy` as a sidecar |
| Tesla BLE (`tesla-control`) | Limited | Yes, local | Free | Good; subprocess with allowlisted arguments |
| Smartcar | Normalised multi-brand | Limited (100/month on Build) | Free tier: 1 vehicle | Good for VW Group, Volvo |
| BMW CarData | 244 metrics over MQTT | Reportedly none | Free | Good read-only feed |
| Unofficial (kia_uvo etc.) | Yes | Yes | Free | Fragile; terms-of-service risk |
| EU Data Act request | Raw and pre-processed data | None | Free to the user | Batch or portal; varies by OEM |

The legal backbone here is the **EU Data Act**, which has applied since September 2025. The Commission's vehicle guidance places raw data, explicitly including **raw CAN messages**, and pre-processed data such as battery level and system states in scope. It also says the Act "does not set rules on access to vehicle functions or resources", even though remote lock, pre-conditioning and charging management count as related services ([EUR-Lex C/2025/5026](https://eur-lex.europa.eu/eli/C/2025/5026/oj/eng)). Users get access free of charge in machine-readable form and can direct it to third parties ([Taylor Wessing](https://www.taylorwessing.com/de/insights-and-events/insights/2026/01/faq-access-to-vehicle-data-and-data-governance)). So the law guarantees your agent's eyes, but its hands remain at each OEM's discretion. Agent integrations already exist. Teslemetry runs a hosted MCP server with generic `send_command` plus lock, charge and wake tools. Its only safety guidance is that the agent gets the same control you have, so you should connect only trusted agents ([Teslemetry MCP](https://teslemetry.com/docs/mcp/introduction)). A self-hosted Zig harness can do better by exposing named, allowlisted commands instead of a generic pass-through.

## The CAN bus is readable, but gateways decide what you can see

Inside the car, Linux is genuinely the right tool. SocketCAN makes a CAN bus an ordinary network interface (`can0`). Raw classic and FD frames, kernel filters, error frames, timestamps, kernel cyclic sending (BCM) and kernel ISO-TP all go through BSD sockets ([kernel SocketCAN docs](https://docs.kernel.org/networking/can.html); [kernel ISO-TP docs](https://docs.kernel.org/networking/iso15765-2.html)). Kernel ISO-TP matters most for EVs, because multi-frame diagnostic replies such as cell-voltage blocks arrive as a single datagram. That means a Zig harness never has to implement the transport protocol itself.

The catch is that **legislated OBD-II gives an EV almost nothing useful**. The valuable data sits behind manufacturer diagnostic identifiers on the BMS and other ECUs. For Hyundai/Kia E-GMP cars (Ioniq 5, EV6), the open OVMS project polls SoC, SoH, min/max cell voltages with cell numbers, pack and inlet temperatures, available charge power, OBC state and 12V converter figures ([OVMS Ioniq 5 docs](https://docs.openvehicles.com/en/latest/components/vehicle_hyundai_ioniq5/docs/index.html)). Even OVMS implements **no** lock, climate or charge control on E-GMP. The SoH figure is the BMS's own number, and owners note there is no public documentation of how Hyundai computes it ([TorqueNews](https://www.torquenews.com/18000/obd2-scanner-shows-100-soh-after-22000-miles-i-cannot-find-any-technical-details-how-soh)). CanZE covers Renault ZE cars ([CanZE](https://github.com/fesch/CanZE)), Car Scanner covers the MG4 ([MGEVs](https://www.mgevs.com/threads/car-scanner-app-now-has-mg4-support.10912/page-2)), and Home Assistant users have worked out BYD Atto 3 SoC ([HA community](https://community.home-assistant.io/t/source-for-byd-atto-3-battery-state-of-charge/603428?page=3)). These are your sources for per-model identifier tables.

**Tesla is the exception that makes a passive agent easy.** Service bulletin CD-20-17-001 officially documents a "third-party CAN bus interface" for Model 3/Y on connector X181: 500 kbps on pins 6 and 14, with an accessory feed on pin 16. It lists broadcast signals such as a go-to-sleep flag on ID 261 and a power state (Off/Conditioning/Accessory/Drive). Tesla disclaims support and says installers act at their own risk ([Tesla CD-20-17-001 R4](https://service.tesla.com/docs/ServiceBulletins/External/CD/CD-20-17-001_Model_3Y_Third-Party_CAN_Bus_Interface_R4.pdf)). Scan My Tesla lists adapter harnesses through the 2025 Juniper Model Y ([Scan My Tesla](https://sites.google.com/view/scanmytesla/adapters)). On a Tesla, then, a listen-only box decodes rich broadcast traffic without ever transmitting.

Most other brands put a **security gateway** between the OBD port and the internal buses. Unauthenticated tools can still read DTCs and live data, but clearing DTCs, actuator tests and coding are blocked until online OEM authentication. That means AutoAuth for Stellantis, ODIS tokens for VW's SFD/SFD2, certificates for Mercedes and server authentication for Renault. Hyundai/Kia "blocks only advanced functions" ([Klavkarr](https://www.klavkarr.com/blog/56-understanding-secure-gateway)). The research also points to a constraint it could not verify from a primary source: on gatewayed cars, broadcast powertrain traffic generally does not reach the OBD pins. If that holds, **on a VW, Hyundai or Renault EV you can only get BMS data by asking for it**, and asking means transmitting. This tension between a silent tap and useful data on non-Tesla cars shapes the plan below.

Hardware choice follows from this. The kernel documents the ELM327 driver as "best effort": half-duplex, prone to buffer overflow under load, and without real-time error notifications ([kernel can327 docs](https://docs.kernel.org/networking/device_drivers/can/can327.html)). An ELM327 is acceptable for slow polling but nothing more. For an always-in-car agent, use a real CAN controller. One example is Waveshare's isolated 2-channel CAN FD HAT, which uses mainline `mcp251xfd` overlays ([Waveshare wiki](https://waveshare.com/wiki/2-CH_CAN_FD_HAT)). Note that Waveshare does not list Pi 5 compatibility. For the tap itself, use **hardware-silent** interfaces. Kvaser's USBcan Pro 4xCAN Silent is "internally wired by hardware to be permanently silent". It never transmits frames, error frames or even the ACK slot, so neither a software fault nor an attacker can turn it into a transmitter ([Kvaser](https://kvaser.com/knowledge-base/how-is-the-kvaser-usbcan-pro-4xcan-silent-hacker-proof/)). A software listen-only flag is weaker, because software can turn it off.

## Writing to CAN is where hobby projects meet car thieves

A write path can mean two things, and both are dangerous. The first is diagnostic services addressed to an ECU, such as IO control, routines, coding and DTC clearing. The second is spoofing broadcast messages that another ECU normally sends. The 2023 theft of Ian Tabor's Toyota RAV4 shows the second in practice. Thieves pulled headlamp wiring to reach the bus and injected messages posing as the smart-key receiver to unlock the car and disable the immobiliser. The injected traffic made other ECUs log camera and hybrid-control faults. As Ken Tindell put it, internal messages in most cars aren't authenticated and receivers trust them ([The Register](https://www.theregister.com/2023/04/06/can_injection_attack_car_theft)). Any write your agent performs uses that same trust, and so does any write an attacker performs through your agent.

The failure modes are concrete. Plausibility faults and DTCs from conflicting messages are documented in the Toyota case. Beyond that, the research notes list ADAS self-disabling on implausible data, bus-off conditions from malformed transmissions, and bricked ECUs from interrupted coding. openpilot shows how quickly an aftermarket change can remove a type-approved safety function: comma warns that enabling longitudinal control (alpha) "will disable all CMBS functionality, including AEB and FCW" ([comma.ai/vehicles](https://www.comma.ai/vehicles)). Wikipedia reports that NHTSA opened an investigation into openpilot in September 2026 citing five crashes ([Wikipedia](https://en.wikipedia.org/wiki/Openpilot)). This is a secondary source and was not verified against NHTSA.

There is a well-tested design to copy. comma's panda **boots in `SAFETY_SILENT`**, with buses silenced until a safety mode is selected. Per-car safety code compiled into its firmware whitelists and limits what may be transmitted, and permissive modes such as `allOutput` are disabled in release builds ([commaai/opendbc](https://github.com/commaai/opendbc); [commaai/panda](https://github.com/commaai/panda)). The existing LLM-to-car projects do none of this. Jan Spoerer's OBD-II MCP server and similar 2025–2026 projects are thin Python wrappers over python-OBD/pyobd that expose legislated PIDs and DTCs, with no EV-specific data and no safety model discussed ([Spoerer, 2025](https://janspoerer.github.io/post/2025/10/18/mcp-obd-ii.html)). No Zig SocketCAN agent with an EV focus and a safety model turned up. That is both a warning and an open niche.

## Polish and EU law tolerates a passive box and little more

UNECE R155 (cybersecurity) and R156 (software updates) bind manufacturers through type-approval audits. As the UK approval authority puts it, "only vehicle manufacturers can obtain approval according to UN R155" ([UK VCA](https://www.vehicle-certification-agency.gov.uk/connected-and-automated-vehicles/cyber-security-and-software-updating/)). So a private owner adding a separate, read-only box is not a "manufacturer". The exposure is national roadworthiness law and the fact that Europe demands **advance approval** for driver assistance. Even Tesla's FSD Supervised needed an RDW type approval, valid only in the Netherlands as of April 2026, and RDW stresses that "the driver remains responsible" ([RDW](https://www.rdw.nl/en/news/2026/rdw-explanation-of-european-type-approval-tesla-with-provisional-validity-in-the-netherlands)). The research found no comma statement, and no EU or member-state approval, that makes openpilot legal on EU roads. It also found no Polish police or ministry statement on retrofit driver assistance.

In Poland, PoRD art. 81 ust. 11 requires an additional inspection (*dodatkowe badanie techniczne*) in three cases: construction changes that alter registration data, a referral by traffic authorities on suspicion of a safety threat, or damage found during an inspection ([arslege.pl, art. 81](https://arslege.pl/prawo-o-ruchu-drogowym/k168/a22361/)). A plug-in box triggers none of these. Visible wiring in airbag zones or warning lights could invite a referral. The rule most likely to bite day to day is distraction. Art. 45 ust. 2 pkt 1 bans using a hand-held phone while driving, with a **500 zł fine and 12 penalty points**, and police apply it at red lights and in jams. A phone in a fixed holder is legal ([Auto Świat](https://www.auto-swiat.pl/porady/korzystanie-z-telefonu-podczas-jazdy-za-co-naprawde-grozi-mandat-i-punkty-karne/2x9bs3k)). That makes a voice-first agent the defensible design.

Insurance divides cleanly. OC recourse against the driver is limited to a closed list (intent, alcohol or drugs, a stolen vehicle, no licence, fleeing the scene), and technical condition is not on it ([arslege.pl, art. 43](https://arslege.pl/prawo-dochodzenia-wyplaconego-odszkodowania-od-kierujacego-pojazdem-mechanicznym/k150/a14007/)). AC is governed by each insurer's terms (OWU). These commonly let insurers cite damage caused by poor technical condition ([mubi.pl](https://mubi.pl/poradniki/wylaczenia-z-ubezpieczenia-ac/)), and mechanical modifications should be reported ([Link4](https://www.link4.pl/blog/zmiany-konstrukcyjne-pojazdu-oc-i-dowod-rejestracyjny)). The realistic AC risk is causation: a fire from a DIY 12V install, or a crash while home-made code was steering. Warranty follows the same causation logic. The Commission's competition FAQ says a warranty cannot be conditional on using the authorised network or OEM parts, but a manufacturer "may legitimately refuse" a claim causally linked to the alternative part ([EC FAQ](https://competition-policy.ec.europa.eu/system/files/2021-09/FAQ_application_of_EU_antitrust_rules_in_the_motor_vehicle_sector_en.pdf)). The block exemption behind it runs to 31 May 2028 ([Cuatrecasas](https://www.cuatrecasas.com/en/global/art/eu-commission-prolongs-motor-vehicle-block-exemption-regulation)). A read-only dongle cannot lawfully void the whole warranty. A 12V drain or a bus-error fault it causes can defeat a specific claim. Rooting or flashing sits on much weaker ground, because the FAQ concerns repair and parts, not firmware tampering.

Two lighter regimes complete the picture. The AI Act does not apply to deployers who are natural persons using AI "in the course of a purely personal non-professional activity" ([AI Act Art. 2](https://ai-act-service-desk.ec.europa.eu/en/ai-act/article-2)). GDPR's household exemption covers personal dashcam-style recording, but publishing identifiable people without consent does not fall under it ([Auto Świat](https://www.auto-swiat.pl/porady/prawo/czy-mozna-publikowac-nagrania-z-kamerek-samochodowych-to-mowi-polskie-prawo/7gthsx0)). Both exemptions end the moment the harness becomes a product you sell.

| Activity | Technical risk | Legal and insurance exposure (PL/EU) |
|---|---|---|
| Cloud reads, Data Act export | None | None for personal use |
| Allowlisted cloud commands while parked | Low (12V drain from wakes) | None identified |
| Hardware-silent CAN tap, external box | Very low (installation, 12V) | Low; disclose permanent installs to AC insurer |
| Read-only UDS polling | Low to moderate (transmits; can keep the car awake) | Low; warranty causation if faults arise |
| UDS writes, coding, DTC clearing | High | Warranty causation; gateway bypass is ToS-hostile |
| Steering, braking, throttle actuation | Severe | No approval route; full driver liability; AC disputes |

## Power, heat and sleep decide whether the box is practical

EVs sleep aggressively, and their 12V batteries are small. Hyundai traced the Ioniq 5's 12V-drain problems mainly to third-party apps waking the car. Some cars received **around 5,000 requests a day**, and Hyundai capped server traffic at **20 transactions per day**. Some 12V batteries needed replacement after repeated deep discharge ([InsideEVs](https://insideevs.com/news/658984/hyundai-finds-causes-for-ioniq-5-12v-battery-drain-reveals-fixes/)). An in-car agent that polls the bus causes the same failure locally. Tesla's X181 pin 16 powers accessories only while the car is awake. It supplies 1000 mA on pre-April-2024 cars and 4000 mA on newer ones ([Tesla CD-20-17-001 R4](https://service.tesla.com/docs/ServiceBulletins/External/CD/CD-20-17-001_Model_3Y_Third-Party_CAN_Bus_Interface_R4.pdf)). In 2024 Tesla cut 12V and USB power in Sentry Mode, then reportedly added a "Keep Accessory Power On" option that runs until the pack falls to 20% ([Notebookcheck](https://www.notebookcheck.net/Tesla-to-restore-Model-Y-12V-and-USB-outlets-power-it-cut-in-Sentry-Mode.995559.0.html)). The box has to sleep when the car sleeps. A car-power HAT such as the CarPiHAT PRO 5 provides 12V-sense safe shutdown and draws **under 1 mA when off** ([The Pi Hut](https://thepihut.com/products/carpihat-pro-5-car-interface-dac-for-raspberry-pi-5)).

Platform choice is a trade between control, price and local AI. A **Raspberry Pi 5** is the cheapest controllable option, but DRAM shortages pushed prices up repeatedly in 2026, adding $30 to the 8GB model in February alone ([Raspberry Pi](https://raspberrypi.com/news/more-memory-driven-price-rises)). A **Jetson Orin Nano Super** costs $249, runs at 7–25 W ([CNX Software](https://cnx-software.com/2024/12/18/249-nvidia-jetson-orin-nano-super-developer-kit-targets-generative-ai-applications-at-the-edge/)) and decodes INT4 Llama 3.2 3B at about 43 tok/s and Llama 3.1 8B at about 19 tok/s ([NVIDIA](https://developer.nvidia.com/blog/nvidia-jetpack-6-2-brings-super-mode-to-nvidia-jetson-orin-nano-and-jetson-orin-nx-modules)). That is enough for intent routing and telemetry summaries, but weak for multi-step planning. Jetson AGX Thor reaches about 150 tok/s on 8B models, but costs $3,499 and draws 40–130 W ([NVIDIA](https://developer.nvidia.com/blog/introducing-nvidia-jetson-thor-the-ultimate-platform-for-physical-ai/)), which is viable only while the car is awake. The **comma four** is the most polished option. It has a Snapdragon 845, Ubuntu 24.04-based AGNOS, 128GB of storage, LTE, native CAN FD through the OBD-C harness and SSH. It sells for $799 in the current promotion plus $30 international shipping, with Polish VAT and any duties on top, and harnesses exist for Tesla, Ioniq 5, VW ID.4 and others ([comma four shop](https://comma.ai/shop/comma-four); [comma compare](https://comma.ai/compare); [agnos-builder](https://github.com/commaai/agnos-builder)). Its CAN, however, goes through the panda MCU. Whether a custom process can share it with openpilot, or open it as SocketCAN, was not verified. And its headline driving feature is the part with no EU approval. The realistic architecture is hybrid: a small local model for offline routing, with frontier cloud LLMs over LTE for reasoning.

## A five-stage plan from cloud reads to a silent tap

Each stage is useful on its own, and you should move on only when the previous one runs reliably. Stages 0–2 never touch the car's wiring.

| Stage | What you build | Hardware | Exit criterion |
|---|---|---|---|
| **0. Desk** | Zig harness core: tool registry, policy engine, audit log, `vcan0` replay of recorded CAN logs, mock vehicle API | Laptop or home server; WSL 2 on Windows works (its kernel has `vcan`) | Harness passes replay tests; LLM-facing tools are named reads only |
| **1. Cloud read-only** | Ingest Tesla `vehicle_data_cached` / Fleet Telemetry, BMW CarData MQTT, Smartcar (free tier), or a Data Act export. Agent answers range, charging and SoH questions | Home server or VPS | Runs for weeks with zero wakes caused by the agent; within Tesla's $10 credit |
| **2. Cloud commands, allowlisted** | Add 3–5 commands: charge limit, charge start/stop, climate precondition, seat heat. Require car parked, human confirmation, rate limits and audit. Tesla via `tesla-http-proxy` sidecar or BLE `tesla-control` | Same | Every command logged and confirmed; no lock, unlock, trunk or summon from the LLM |
| **3. In-car box, hardware-silent tap** | Pi 5 (or comma four used purely as a data computer) + car-power HAT + hardware-silent CAN interface. Passive DBC decoding; sleep on bus silence; voice-only output | Tesla: X181 harness. Others: expect little broadcast data at the OBD port | Car behaves identically with the box unplugged; no new DTCs; parked 12V stable |
| **4. Read-only diagnostic polling** | Separate, physically switchable polling interface. Kernel ISO-TP reads (UDS 0x22, 0x19) of a fixed allowlist of IDs from OVMS/CanZE/Car Scanner tables. Parked or charging only at first, low rate, stops on any error frame | Second CAN channel (non-silent) behind a physical switch | Weeks of polling with zero DTCs, no bus-off, no prevented sleep |
| **5. Local model (optional)** | Jetson Orin Nano Super running a 3–8B model over local HTTP for offline intent routing; cloud fallback | Jetson, awake-only power | Box sleeps with the car; thermal shutdown tested in summer |

On a Tesla, Stage 3 delivers most of the value, because the broadcast bus already carries pack, motor, HVAC and power-state data. On a VW, Hyundai, Renault or BYD, Stage 3 is mostly about building the box and its power discipline. The BMS data only arrives in Stage 4, which is why Stage 4 is kept parked-only, rate-limited and physically separated from the silent tap. There is deliberately no stage for CAN writes. Vehicle-affecting actions belong to the OEM's cloud API, which runs through the OEM's own authenticated command path and safety checks.

## Red lines that no stage crosses

| Never | Why |
|---|---|
| Actuate steering, braking, acceleration or lighting, or change ADAS settings | No type-approval route for an individual; full driver liability; AC claim disputes |
| Run openpilot longitudinal "alpha" or anything that disables AEB/FCW | Removes a mandatory, type-approved safety function ([comma.ai/vehicles](https://www.comma.ai/vehicles)) |
| Send UDS session control into extended or programming sessions (0x10), SecurityAccess (0x27), WriteDataByIdentifier (0x2E), IO control (0x2F), RoutineControl (0x31), ClearDTC (0x14), ECUReset (0x11), or download/flash services (0x34–0x37) | These are exactly the coding and actuation functions gateways block ([Klavkarr](https://www.klavkarr.com/blog/56-understanding-secure-gateway)); they can brick ECUs or latch SRS/ABS faults |
| Spoof broadcast messages on any bus | The RAV4 theft technique; causes plausibility faults across ECUs ([The Register](https://www.theregister.com/2023/04/06/can_injection_attack_car_theft)) |
| Use SGW/SFD bypass modules, root the head unit, or reflash ECUs on your daily driver | Weakest warranty position; non-persistent root on Tesla; risk to the main screen |
| Tap HV wiring or the BMS harness | Fire and electrocution risk; the clearest causation argument for an AC insurer |
| Expose raw frames or generic `send_command` to the LLM | Prompt injection from messages or web content must never reach a vehicle-affecting tool |
| Transmit while the bus is asleep, or wake the car repeatedly | The Ioniq 5 drain pattern ([InsideEVs](https://insideevs.com/news/658984/hyundai-finds-causes-for-ioniq-5-12v-battery-drain-reveals-fixes/)) |
| Run inbound network services on the in-car box | Insecure telematics dongles are a known path onto vehicle buses ([Kaspersky](https://www.kaspersky.com/blog/progressive-snapshot-car-hacking/7284/)) |
| Require the driver to touch or hold a device while driving | 500 zł and 12 points under art. 45 PoRD |
| Record passenger audio by default, or publish identifiable footage | Leaves GDPR's household exemption; personal-rights claims |
| Mount the box or wiring in airbag zones or the field of view | Grounds for police referral to additional inspection under art. 81 PoRD |

## Zig implementation notes (Zig 0.17.1)

These notes are for Zig 0.17.1, the version the zigworks tools pin. The code they quote is in [`cantap/`](cantap/), which builds a listen-only tap and its tests; what was run, and what was not, is at the end of this section.

**Talk to SocketCAN through `std.os.linux`, with the CAN structures written out and checked.** Zig 0.17.1 no longer has `@cImport`. The sketch in the first version of this note used it and now stops with `error: invalid builtin function: '@cImport'`. C headers are translated by a build step instead (`b.addTranslateC`) and imported as a module. Done that way, the sketch compiles and runs unchanged, and translate-c copes with the structures' union and aligned members: the sketch's size asserts pass. It is kept in `cantap/sketch/`. It still needs libc, though, and the zigworks tools use none, which suits a static tap better. Zig's CAN ecosystem is nearly empty. The only library found, `Hedwyn/canzig`, wraps raw send and receive, has no filtering, ISO-TP or stated FD support, and has 2 stars ([canzig](https://github.com/Hedwyn/canzig)). The standard library covers the kernel calls: `socket`, `bind`, `setsockopt`, `poll`, and `ioctl` with `SIOCGIFINDEX` and `ifreq` to find an interface's index without libc's `if_nametoindex`. It has the CAN address family but none of the CAN structures. Those are three small `extern struct`s: `canfd_frame` (72 bytes; a classic `can_frame` of 16 bytes has the same layout up to its eight data bytes), `can_filter` (8 bytes) and `sockaddr_can` (24 bytes) ([kernel SocketCAN docs](https://docs.kernel.org/networking/can.html)). Comptime asserts hold their sizes. `check_abi.c`, a list of `_Static_assert`s compiled with `zig cc` for each target, holds every hand-written constant and offset against the kernel headers Zig ships.

```zig
// from cantap/src/can.zig
const std = @import("std");
const linux = std.os.linux;

/// struct canfd_frame. A classic frame (struct can_frame, 16 bytes) has the
/// same layout up to its 8 data bytes; `Tap.read` says which kind came in.
pub const Frame = extern struct {
    id: u32,
    len: u8,
    flags: u8 = 0, // CAN FD only: bit-rate switch, error state
    res0: u8 = 0,
    res1: u8 = 0, // len8_dlc in a classic frame
    data: [64]u8 align(8) = @splat(0),
    // ident() and payload() left out here
};
pub const classic_size = 16; // CAN_MTU
comptime {
    std.debug.assert(@sizeOf(Frame) == 72); // CANFD_MTU
    std.debug.assert(@offsetOf(Frame, "data") == 8);
}

/// struct can_filter: a frame passes when `frame.id & mask == id & mask`.
pub const Filter = extern struct {
    id: u32,
    mask: u32,

    /// Exactly one 11-bit id: not the 29-bit id with the same low bits,
    /// and not a remote request.
    pub fn exact(id: u11) Filter {
        return .{ .id = id, .mask = eff_flag | rtr_flag | sff_mask };
    }
};

/// A raw CAN socket that only reads.
pub const Tap = struct {
    fd: linux.fd_t,

    pub const Options = struct {
        /// Frames that match any of these; empty: every frame.
        filters: []const Filter = &.{},
        /// Error frames too (bus-off, error-passive); a tap should watch them.
        errors: bool = true,
        /// CAN FD frames too.
        fd_frames: bool = false,
    };

    pub fn open(ifname: []const u8, opts: Options) !Tap {
        const fd = try socket(linux.SOCK.RAW, can_raw);
        errdefer _ = linux.close(fd);
        if (opts.filters.len > 0) try setOption(fd, sol_can_raw, raw_filter, std.mem.sliceAsBytes(opts.filters));
        if (opts.errors) try setOption(fd, sol_can_raw, raw_err_filter, std.mem.asBytes(&err_mask));
        const on: i32 = 1;
        if (opts.fd_frames) try setOption(fd, sol_can_raw, raw_fd_frames, std.mem.asBytes(&on));
        try bind(fd, .{ .ifindex = try interfaceIndex(fd, ifname) });
        return .{ .fd = fd };
    }

    /// The next frame, waiting up to `timeout_ms` (-1: no limit).
    /// null: nothing came in time.
    pub fn read(t: Tap, frame: *Frame, timeout_ms: i32) !?Kind {
        if (!try readable(t.fd, timeout_ms)) return null;
        const n = linux.read(t.fd, std.mem.asBytes(frame), @sizeOf(Frame));
        try ok(n);
        if (frame.id & err_flag != 0) return .err;
        return switch (n) {
            classic_size => .classic,
            @sizeOf(Frame) => .fd,
            else => error.ShortFrame,
        };
    }

    pub fn close(t: Tap) void {
        _ = linux.close(t.fd);
    }
};

/// struct sockaddr_can (24 bytes). The two ids are for ISO-TP sockets.
pub const Address = extern struct {
    family: linux.sa_family_t = linux.AF.CAN,
    ifindex: i32,
    rx_id: u32 = 0,
    tx_id: u32 = 0,
    rest: [8]u8 = @splat(0), // the union's larger J1939 member
};

/// The index of a network interface such as "can0".
pub fn interfaceIndex(fd: linux.fd_t, name: []const u8) !i32 {
    if (name.len == 0 or name.len >= linux.IFNAMESIZE) return error.NoSuchInterface;
    var req: linux.ifreq = undefined;
    @memset(std.mem.asBytes(&req), 0);
    @memcpy(req.ifrn.name[0..name.len], name);
    try ok(linux.ioctl(fd, linux.SIOCGIFINDEX, @intFromPtr(&req)));
    return req.ifru.ivalue;
}
```

Nothing in `can.zig` writes to a socket, so a binary built from it cannot transmit. A tap asks for error frames by default (`CAN_RAW_ERR_FILTER`), and `can.trouble` turns them into bus-off or error-passive. It asks for CAN FD frames only on request (`CAN_RAW_FD_FRAMES`). `Filter.exact` masks in the extended-id and remote-request flags, so an 11-bit filter does not also let through the 29-bit id with the same low bits. The tests check that.

**Build static, and pin the version.** With no libc, `zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe -Dstrip=true` gives a static binary of about 260 KB for a Pi 5, Jetson or comma four, all aarch64, and about 360 KB for x86_64. Pin the version in `build.zig.zon` (`.minimum_zig_version = "0.17.1"`), because the standard library changes between releases. Besides `@cImport` going, 0.17.1 routes file and terminal output, processes and HTTP through an `std.Io` value, so guides written for older versions often no longer match.

**Use the kernel for transport, and make the allowlist part of the type.** For Stage 4, open one `SOCK_DGRAM`/`CAN_ISOTP` socket per request, bound to its fixed `tx_id`/`rx_id`. Each UDS response then arrives as one `read()` ([kernel ISO-TP docs](https://docs.kernel.org/networking/iso15765-2.html)). In the tests, a 63-byte answer, which the kernel sends as a first frame and eight consecutive frames, came back as a single 63-byte read. Instead of checking outgoing bytes at run time, `isotp.Poller` takes the table of allowed requests as a compile-time parameter. It checks every entry while compiling, and `ask` takes the entry's index, also at compile time. No argument exists through which other bytes could reach the bus.

```zig
// from cantap/src/isotp.zig
pub fn Poller(comptime table: []const Request) type {
    comptime for (table) |r| readOnly(r);
    return struct {
        // one ISO-TP socket per entry, bound to its tx_id and rx_id
        ...
        /// Sends entry `i` of the table and waits up to `timeout_ms` for the
        /// whole answer, however many frames it took. null: no answer.
        pub fn ask(self: *Self, comptime i: usize, reply: []u8, timeout_ms: i32) !?[]u8 { ... }
    };
}

/// Only the two services that read. Everything else (sessions, security
/// access, writing, IO control, routines, clearing codes, reset, flashing)
/// stops the build.
fn readOnly(comptime r: Request) void {
    if (r.bytes.len == 0) @compileError("empty request");
    switch (r.bytes[0]) {
        read_data_by_identifier => if (r.bytes.len < 3 or r.bytes.len % 2 != 1)
            @compileError("0x22 takes one or more two-byte identifiers"),
        read_dtc_information => if (r.bytes.len < 2)
            @compileError("0x19 needs a sub-function"),
        else => @compileError(std.fmt.comptimePrint("service 0x{x:0>2} is not read-only", .{r.bytes[0]})),
    }
}
```

A table is a constant in the program (the ids here are examples, not any car's):

```zig
const Bms = isotp.Poller(&.{
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x22, 0x01, 0x01 } }, // ReadDataByIdentifier
    .{ .tx_id = 0x7e4, .rx_id = 0x7ec, .bytes = &.{ 0x19, 0x02, 0xff } }, // ReadDTCInformation
});
var bms = try Bms.open("can0", .{ .pad = 0xaa });
var reply: [4095]u8 = undefined;
const answer = try bms.ask(0, &reply, 1000); // null: no answer within 1 s
```

An entry with WriteDataByIdentifier (`0x2e`) stops the build:

```
src/isotp.zig:109:17: error: service 0x2e is not read-only
```

Two details matter on real ECUs, and `ask` handles both. An answer `7F <service> 78` ("response pending") means the real answer is still to come, so it waits on. A late answer to an earlier request is drained before the next request goes out. Many ECUs also want short frames padded to 8 bytes: `.pad = 0xaa` sets `CAN_ISOTP_TX_PADDING`. `isotp.positive` tells a positive answer (the service plus 0x40) from a negative one (`0x7f`). Because the plan stays in the default diagnostic session, you never need BCM TesterPresent keep-alives, and leaving them out is itself a safety property. Zig compiles only code that is referenced, so a tap executable that never imports `isotp.zig` contains no transmit path. Make that visible in the build rather than leaving it to the call graph: build the tap and the poller as separate executables, with the poller behind a build option (`-Dcan-poll=false` by default). Model the LLM tool interface as a Zig tagged union with an exhaustive `switch`. Then there is literally no `send_frame` variant to call, and adding one is a compile-time decision rather than a prompt-time one.

**Let systemd enforce the separation the panda enforces in firmware.** Split the system into three services. A tap service may open `AF_CAN` sockets but has no network access. An agent service may reach the network and the cloud APIs but cannot open `AF_CAN` at all. The two talk over a Unix socket that carries decoded signals, never raw frames. Use `RestrictAddressFamilies=AF_CAN AF_UNIX` on the tap and `AF_INET AF_INET6 AF_UNIX` on the agent, together with `NoNewPrivileges=yes`, `ProtectSystem=strict`, an empty `CapabilityBoundingSet=` and `IPAddressDeny=any` on the tap. Bring up `can0` in systemd-networkd with a `[CAN]` section (bitrate and listen-only, if your systemd version and driver support it) rather than giving any Zig process `CAP_NET_ADMIN`. The tap finds the interface with `SIOCGIFINDEX` on its own CAN socket, so it needs no other address family. A software listen-only flag is defence in depth, not a substitute for the hardware-silent interface. For liveness, implement `sd_notify` yourself. It is one datagram such as `WATCHDOG=1` sent to the socket named in `$NOTIFY_SOCKET`. A name starting with `@` is an abstract socket, whose address starts with a zero byte. In 0.17.1, `main` can take a `std.process.Init`, whose `environ_map` holds the environment, so reading the variable needs no libc either. You can then set `WatchdogSec=` without linking libsystemd and keep the binary static.

```zig
// from cantap/src/notify.zig
/// Sends `message` ("READY=1", "WATCHDOG=1", "STOPPING=1") to systemd.
/// `socket_path` is the value of $NOTIFY_SOCKET: null when the program was
/// not started by systemd, and then nothing is sent.
pub fn notify(socket_path: ?[]const u8, message: []const u8) !void {
    const path = socket_path orelse return;
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len < 2 or path.len >= addr.path.len or (path[0] != '/' and path[0] != '@'))
        return error.BadNotifySocket;
    @memcpy(addr.path[0..path.len], path);
    if (path[0] == '@') addr.path[0] = 0; // an abstract socket
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NotifyFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len);
    if (linux.errno(linux.sendto(fd, message.ptr, message.len, 0, @ptrCast(&addr), len)) != .SUCCESS)
        return error.NotifyFailed;
}
```

Treat **bus silence** for N seconds, or Tesla's go-to-sleep signal on ID 261, as "car asleep". When the car is asleep, stop all transmission, flush logs and request shutdown so the power HAT can cut the board. The example tap does the silence part: it sends `WATCHDOG=1` at most once a second while frames arrive, and after 10 s with none it sends `STOPPING=1` and exits.

```zig
// from cantap/src/main.zig
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    ...
    const sock = init.environ_map.get("NOTIFY_SOCKET");
    try notify(sock, "READY=1");
    ...
    while (try tap.read(&frame, silent_ms)) |kind| {
        // WATCHDOG=1 at most once a second, then the frame to stdout:
        // try Io.File.stdout().writeStreamingAll(io, text);
        ...
    }
    try notify(sock, "STOPPING=1");
    return 0;
}
```

**Keep the hard parts in sidecars and codegen.** Tesla's command signing exists officially only in Go. Run `tesla-http-proxy` on loopback and call it from `std.http.Client`, or spawn `tesla-control` for BLE with an allowlisted argv, instead of reimplementing the ECDH and protobuf session protocol ([vehicle-command](https://github.com/teslamotors/vehicle-command)). In 0.17.1 both go through an `Io`: `std.process.spawn(io, .{ .argv = ... })` starts a process, and a client is made as `std.http.Client{ .allocator = gpa, .io = io }`. If the proxy serves HTTPS with its own certificate, add that certificate to the client's `ca_bundle` (`addCertsFromFilePath`), or Zig's TLS client will refuse the connection. No Zig DBC parser was found. Generate Zig signal tables offline from opendbc's MIT-licensed DBCs and parser ([opendbc](https://github.com/commaai/opendbc)) into a `comptime` array of `{id, start_bit, length, factor, offset, endianness}`. That makes decoding branch-light and allocation-free. Run any local LLM (llama.cpp or JetPack's runtime) as its own process behind local HTTP. That keeps CUDA and glibc out of your static agent, and an LLM crash cannot take the CAN tap down with it.

**What was run, on 22 Nov 2026.** Zig 0.17.1 under WSL 2 on Windows 11, Linux 6.18.58, whose kernel ships CAN, ISO-TP and the virtual `vcan` driver as modules, against a `vcan0` interface. So Stage 0 needs no Linux machine, only WSL.

- **Kernel headers:** `check_abi.c` compiles for aarch64 and x86_64, so every hand-written constant, size and offset matches.
- **Tests:** 11 of 11 pass, in Debug and in ReleaseSafe:
  - an 11-bit filter, which lets through neither another id nor the 29-bit id with the same low bits;
  - a 64-byte CAN FD frame;
  - error-frame classes;
  - a missing interface;
  - a multi-frame ISO-TP answer arriving as one read;
  - "response pending" waited out;
  - a negative answer;
  - no ECU: no answer within the timeout, and no hang;
  - `sd_notify` to an abstract socket;
  - the usage example above, compiled (not run: there is no `can0`).
- **The example tap, end to end:** of three frames sent, it printed the two it was asked for. It sent `READY=1`, `WATCHDOG=1` twice and `STOPPING=1` to the notify socket, and exited after 10 s of silence.
- **The first sketch,** with its headers translated in `build.zig`, opens and closes a tap on `vcan0`.
- **Static builds** for aarch64 and x86_64, with the sizes above.

Not run: any real CAN adapter, a hardware-silent interface, a Raspberry Pi, or a car. To run the tests, as root: `modprobe vcan && ip link add dev vcan0 type vcan && ip link set up vcan0`, then `zig build test` in `cantap/`.

**Traffic without a car.** [`cansim/`](cansim/) sets up, in the same WSL distro, the following on `vcan`:

- real CAN traffic to replay: one minute each of a Hyundai Ioniq 5 (mostly CAN FD) and a Tesla Model 3, from comma.ai's commaCarSegments;
- ICSim, a dashboard driven over CAN;
- an ECU simulator for the diagnostic reads.

cantap reads the replays; CAN FD needs `cantap --fd`. Its poller reads identifiers from the ECU simulator, which does ISO-TP itself rather than through the kernel (`zig build test-uds-sim`).

## What was built from this, 22 Nov 2026

Two MCP servers now cover Stages 2 and 3 in software, without a car:

- **[canmcp](../../canmcp/)** is Stage 3's software. It reads CAN through SocketCAN, decodes it with opendbc's DBC files, and gives the agent named readings and waits, never raw frames.
  - The default build contains no code that transmits.
  - Builds with diagnostic reads (Stage 4) send only the fixed, read-only requests compiled into them. The one table so far is for cansim's simulated battery ECU.
  - It decodes the Model 3 and Ioniq 5 recordings consistently (`zig build recordings`). The Model 3's inverter and ABS speeds agree within 1.5 km/h, with a largest gap of 1.04 km/h. The Ioniq 5's minute reads as door open, door closed, seatbelt, reverse.
- **[carcloud](../../carcloud/)** is Stage 2's software, through Smartcar's v3 API.
  - Its commands are allowlisted: charge start and stop, charge limit within a range, lock.
  - It caps commands per day and enforces a gap between two.
  - Unlocking is a tool of its own, off by default. Location is off by default.
  - It was written from Smartcar's documentation and tested only against a stand-in built from the same documentation.

**With harness and a real model.** Both, plus [homemcp](../../homemcp/) for the home, ran under harness in WSL with a real model through omnigate. The Model 3 recording looped on `vcan0` and `vcan2`, and the stand-ins played the cloud and the home. Read-only tools ran without asking. Every command was asked about first: the charge limit, the light, the lock. When asked to unlock the front door, which homemcp's file doesn't allow, the model didn't try. harness's hash-chained log recorded every call and decision.

**Smartcar, corrected.** Smartcar's documentation and pricing page, read on 22 Nov 2026, change four points in the cloud section above:

- **The Free plan allows reading one real car, but includes no commands.** Commands start with the paid plan: from $1.99 per vehicle per month, with 100 commands a month across all vehicles ([pricing](https://smartcar.com/pricing)).
- **In Europe, VW Group cars support only starting and stopping charging through Smartcar.** There is no lock status, no location and no charge limit (Smartcar's public Compatibility API). Tesla supports all of carcloud's commands once the owner installs Smartcar's virtual key.
- **Data can be about a day old.** Without a webhook, Smartcar collects a car's data on a slower baseline schedule, roughly once a day. Calling more often doesn't make it fresher ([frequencies](https://smartcar.com/docs/help/frequencies.md)). carcloud shows the age with every reading.
- **Smartcar's v2.0 API is retired on 1 Dec 2026.** Build on v3, which has no climate command ([migration guide](https://smartcar.com/docs/getting-started/how-to/m2m/migration-guide.md)).

**Still open:** the Tesla Fleet API route (`tesla-http-proxy`), BMW CarData, any real adapter or car, and the in-car box itself: power, heat and sleep.

## Conclusion

The research reverses an intuitive assumption. A harness built to manage low-level Linux gets its safety from controlling *its own* box: process isolation, address-family restrictions, watchdogs and hardware that physically cannot transmit. Reaching deeper into the car adds risk without a matching gain. The legal map lines up with that engineering split. Reading is now a statutory right under the Data Act, explicitly including raw CAN messages, while writing is nobody's right and is gated by OEM servers, gateways and type approval. The strongest design therefore reads locally and acts only through authenticated OEM command paths. The biggest open uncertainty is brand-specific: whether your particular non-Tesla EV exposes anything passively at the OBD port, and which aggregator commands it supports in Poland. Settle both before buying hardware.

There is also a visible gap in the ecosystem. Every existing car MCP server is either a thin Python wrapper over legislated OBD PIDs or a generic pass-through of OEM commands. None combines EV battery data, raw SocketCAN, a compile-time allowlist and a firmware-style silent-by-default safety model. A static Zig harness built to the plan above would be a useful open-source reference in its own right.
