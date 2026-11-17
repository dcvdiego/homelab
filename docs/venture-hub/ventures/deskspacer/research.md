# DeskSpacer: market and capture research

Research date: 4 October 2026. Desk research only: no customer interviews, outreach, publishing, source-code changes, scanning trials, or GPU benchmarks performed.

## Assessment

The strongest supported hypothesis is a mixed-brand planner that accommodates existing equipment and checks physical fit. A photo-to-object workflow is a promising onboarding feature. Reliable custom dimensions and simple proxies can test its value before building native scanning. Forum interest establishes problems and desired features; it does not establish market size, conversion rates, or willingness to pay.

## Evidence register

| Source | Observed problem or behaviour | Product implication | Confidence and limits |
|---|---|---|---|
| [DeskSpacing launch discussion, July 2020](https://www.reddit.com/r/InternetIsBeautiful/comments/hr8unj/i_made_a_website_with_a_friend_that_allows_you_to/) | Users request custom desktops, L-shaped desks, generic objects, room context, metric units, monitor rotation and easier controls. Some describe paper or Blender workarounds. | Support arbitrary dimensions, generic objects and visible controls; let users recreate their actual room. | Direct user feedback, but old and largely one launch thread. These are category requirements, not evidence current competitors lack them. |
| [Planner complaint, July 2024](https://www.reddit.com/r/desksetup/comments/1egyzwh/looking_for_desk_recommendations_that_support_my/) | A user says DeskSpacing's desk choices are limited and performance is poor. | Missing equipment must have an escape hatch; test browser performance with real scenes. | One user, not a measured failure rate. |
| [Monitor rotation complaint, April 2022](https://www.reddit.com/r/pcmasterrace/comments/u9f18b/) | A user wants to model their setup to choose speakers and cannot find how to rotate monitors in the planner. | Orientation and speaker placement affect actual purchases. | One user; perceived functionality can reflect discoverability rather than absent code. |
| [Synth/Gear Planner, July 2026](https://www.reddit.com/r/synthesizers/comments/1uw65lr/synthgear_planner_in_the_making/) | A builder uses cropped top-down equipment photos and supplied dimensions. Commenters appreciate scale and suggest 3D racks and constraint solving. | Photo plus dimensions is a credible alternative to a full mesh catalogue. Music equipment is a relevant testing segment. | Recent direct feedback; free interest is not payment evidence. |
| [Complex studio planning, May 2025](https://vi-control.net/community/threads/best-online-program-editor-for-replanning-a-complex-studio-multi-pc-synth-cabling-midi-etc.163565/) | A studio user finds paper planning messy and wants physical placement plus USB/MIDI/audio wiring and approximate cable lengths. They mention reasonably priced subscription or one-time software. | Shared spatial and connection data could serve studio planning. | Specific purchase-interest signal from one person; insufficient for pricing conclusions. |
| [Clamp/desk frame conflict, September 2026](https://www.reddit.com/r/desksetup/comments/1wllwuv/had_this_layout_for_years_and_im_sick_and_tired/) | Under-desk frame obstructs a clamp; user also discusses speaker size, audio interface, cables and multiple computers. | Model underside obstacles, mounting geometry and existing equipment. | Direct detailed problem; forum suggestions are not engineering validation. |
| [Shallow desk and inaccessible edges, September 2026](https://www.reddit.com/r/buildapc/comments/1wlalgn/need_help_on_monitor_stand_space_issues_on_my_desk/) | Stock stand consumes desk depth; hutch/backboard prevents clamping. | Stand footprint and accessible mounting zones matter more than monitor diagonal alone. | Direct problem. |
| [Thick desk, April 2026](https://www.reddit.com/r/WFH/comments/1sd6vrk/looking_for_a_suitable_monitor_arm_for_my_thick/) | User cannot find a clamp compatible with desk thickness and wants to avoid damage. | Compare manufacturer clamp ranges with measured mounting position. | Repeat of the mounting problem in another thread. |
| [Standing desk short cables, September 2023](https://www.reddit.com/r/StandingDesk/comments/16csdb4/) | Peripheral cables become too short as desk rises. | Simulate height states and route lengths with explicitly chosen slack. | Direct recurring class of problem; route approximation does not establish electrical compatibility. |
| [Standing desk cable strain, June 2021](https://www.reddit.com/r/StandingDesk/comments/nqwqx4/) | User worries about connector strain with PC on floor. | Distinguish moving and fixed cable endpoints. | Supports repeated problem across years. |
| [Work-to-gaming switching, September 2026](https://www.reddit.com/r/AskBattlestations/comments/1wbrlp9/how_to_switch_from_work_to_gaming/) | People ask how to connect work laptop, gaming PC and shared peripherals. | Connection diagram could become a separate module. | Demand for help; compatibility scope can become large quickly. |
| [Room layout and tool sizing, September 2025](https://www.reddit.com/r/floorplan/comments/1npto2y/what_are_some_of_the_best_free_or_cheap_floor/) | A home-office planner asks for cheap tools; discussion notes game furniture dimensions are not reliably to scale. | Simple accurate room boundaries offer value without a sophisticated room renderer. | Anecdotal and price-sensitive. |
| [Two desks in constrained room, December 2025](https://www.reddit.com/r/desksetup/comments/1phlj08/desk_setup_advice/) | User models room in SketchUp; combined desk dimensions exceed wall width. | Include walls and multiple desks; export measurements for comparison. | Another concrete workflow, not proof of subscription demand. |

## Competitive baseline

- [Juddesk](https://www.juddesk.com/) advertises free real-scale mixed-brand products, mobile support, saving/sharing and community remixing. Do not pitch these alone as differentiation. Custom imports, mechanical validation and regional shopping coverage remain unverified here. Thai affiliate destinations were observed by the user but not independently verified in this research.
- [Corsair Atelier](https://atelier.corsair.com/) explicitly focuses on the Corsair family, including Elgato, Fanatec, Origin, SCUF and DROP. It validates brand-funded planning as a category. Its presence does not eliminate a mixed-brand offering.
- General CAD/room planners, paper and photo-based gear tools are substitutes. DeskSpacer must reduce the effort to produce a useful plan, not only exceed dedicated competitors' feature lists.

## Adding personal equipment

| Route | Practical approach | Main limitations | Relative implementation work |
|---|---|---|---|
| Dimensioned proxy | Choose object type and supply width/depth/height; create a simple mesh. | Appearance is approximate; dimensions depend on input. | Low relative to the other options. |
| Photo plus dimensions | Crop/segment photo; apply it to a dimensioned proxy or top-down view. | Hidden sides are absent; perspective requires correction. | Low to medium. |
| Imported scan | Capture in external app; import mesh and calibrate size. | Cleanup, excessive geometry, orientation and missing textures. | Medium. |
| Native guided scanning | Build camera/depth capture and upload/export flow. | Native platform maintenance and reconstruction failure cases. | High. |
| Local image-to-3D | Queue generation on 5090, simplify output, set supplied dimensions. | Plausible hidden geometry can be wrong; hardware/runtime unbenchmarked. | Medium to high, useful as an optional experiment. |

[Apple Object Capture guidance](https://developer.apple.com/videos/play/wwdc2023/10191/) describes multiple-image capture and reconstruction, and recommends avoiding reflective, transparent and thin objects. These are relevant characteristics of screens, metal stands and glass cases. No claim of millimetre precision follows from these tools.

[Apple RoomPlan](https://developer.apple.com/augmented-reality/roomplan/) uses camera/LiDAR for room structure, dimensions and recognised furniture; outputs USD/USDZ. It is a room-layout shortcut, not a catalogue generator for every peripheral. Apple exposes depth through its [native camera APIs](https://developer.apple.com/documentation/AVFoundation/capturing-depth-using-the-lidar-camera); do not assume the web frontend can directly invoke the same capture pipeline.

[Polycam export documentation](https://learn.poly.cam/hc/en-us/articles/27756102599572-What-File-Types-Can-Polycam-Export) lists free GLTF exports; [pricing](https://poly.cam/pricing) limits free captures. This supports a cheap manual import trial, not a commitment to unlimited free production processing or a service API.

[Microsoft TRELLIS.2](https://github.com/microsoft/TRELLIS.2) provides MIT-licensed model/code and image-to-3D generation. Upstream lists Linux and at least 24 GB GPU memory, verified on A100/H100. Its published timing is H100 timing; no 5090 benchmark was performed. Dependencies and Blackwell support require testing. Generated appearance should use a separate physical envelope and verified dimensions.

[Hunyuan3D-2.1 licence](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1/blob/main/LICENSE) excludes UK, EU and South Korea from its territorial grant. That particular release is not an appropriate default for this UK-based project under that licence. This is not a claim about every Hunyuan release.

## Proposed experiments

1. **Bring your own item:** compare dimensioned proxies, photo proxies and imported scans on a matte keyboard, mouse, speaker, shiny interface, glass-sided PC and monitor. Track total capture/correction time, completed imports, measured size error and usefulness in planning. Do not require scans for completion.
2. **Fit before purchase:** reproduce clamp/frame, shallow desk and speaker-placement problems. Begin with geometry and documented mounting ranges. Structural suitability and unknown data must remain explicit.
3. **Music equipment:** build one real mixed gaming/music/work setup and test it in 2D and 3D. Compare against the photo-based workflow rather than assuming 3D is always preferred.
4. **Purchase conversion:** pick one country and a small set of properly identified products. Measure completed plans and retailer clicks. Conversion/revenue require actual retailer tracking; no earnings assumptions.
5. **Professional value:** prepare a sample room/gear/connection report. Test interest in saved client projects or brand catalogues before implementing billing.

Proposed recruitment, publishing, account creation, affiliate applications and spending remain subject to the user's approval. No such actions have occurred.

## Product and platform implications

Keep render meshes, physical dimensions, mounting constraints and catalogue identity separate. Record whether dimensions are manufacturer-specified, user-measured or scan-estimated. Private personal models can become optional contributions only with permission and review. This could grow coverage without making every user wait for a catalogue update.

Instant proxies and scene checks run without the 5090. Optional reconstruction jobs wait for the GPU. The agent workflow can prepare product data, process assets, check missing fields and produce review artifacts. User approval remains necessary for publication. Commercial sustainability depends on maintenance time, bandwidth/storage, support and conversion; included AI subscriptions do not remove those costs.
