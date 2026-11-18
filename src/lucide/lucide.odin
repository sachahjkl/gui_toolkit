// The Lucide icons (lucide.dev, ISC licence: LICENSE.txt beside this file), as a font: DATA is its face (font.load_embedded),
// and each constant one icon's character in it, named as the font names its glyph. A program draws an icon as text in
// that face. One set for every program of the toolkit.
//
// -define:LUCIDE_SUBSET=<absolute path>: DATA is that font instead, the icons the program uses (toolbox.lucide_subset,
// Feature.Lucide_Subset: 900 KB less). A constant whose icon it does not hold draws nothing.
//
// Generated from lucide.ttf by `odin run tools/tk -- gen_lucide`: do not edit; a newer font, then that command again.
package tk_lucide

LUCIDE_SUBSET :: #config(LUCIDE_SUBSET, "")

when LUCIDE_SUBSET != "" {
	DATA :: #load(LUCIDE_SUBSET)
} else {
	DATA :: #load("lucide.ttf")
}

A_ARROW_DOWN                       :: "\ue585"   // a-arrow-down
A_ARROW_UP                         :: "\ue586"   // a-arrow-up
A_LARGE_SMALL                      :: "\ue587"   // a-large-small
ACCESSIBILITY                      :: "\ue297"   // accessibility
ACTIVITY                           :: "\ue038"   // activity
ACTIVITY_SQUARE                    :: "\ue4b4"   // activity-square
AD                                 :: "\ue700"   // ad
AIR_VENT                           :: "\ue34d"   // air-vent
AIRPLAY                            :: "\ue039"   // airplay
ALARM_CHECK                        :: "\ue1ec"   // alarm-check
ALARM_CLOCK                        :: "\ue03a"   // alarm-clock
ALARM_CLOCK_MINUS                  :: "\ue1ed"   // alarm-clock-minus
ALARM_CLOCK_OFF                    :: "\ue23b"   // alarm-clock-off
ALARM_CLOCK_PLUS                   :: "\ue1ee"   // alarm-clock-plus
ALARM_SMOKE                        :: "\ue57b"   // alarm-smoke
ALBUM                              :: "\ue03b"   // album
ALERT_CIRCLE                       :: "\ue077"   // alert-circle
ALERT_OCTAGON                      :: "\ue127"   // alert-octagon
ALERT_TRIANGLE                     :: "\ue193"   // alert-triangle
ALIGN_CENTER                       :: "\ue182"   // align-center
ALIGN_CENTER_HORIZONTAL            :: "\ue26c"   // align-center-horizontal
ALIGN_CENTER_VERTICAL              :: "\ue26d"   // align-center-vertical
ALIGN_END_HORIZONTAL               :: "\ue26e"   // align-end-horizontal
ALIGN_END_VERTICAL                 :: "\ue26f"   // align-end-vertical
ALIGN_HORIZONTAL_DISTRIBUTE_CENTER :: "\ue03c"   // align-horizontal-distribute-center
ALIGN_HORIZONTAL_DISTRIBUTE_END    :: "\ue03d"   // align-horizontal-distribute-end
ALIGN_HORIZONTAL_DISTRIBUTE_START  :: "\ue03e"   // align-horizontal-distribute-start
ALIGN_HORIZONTAL_JUSTIFY_CENTER    :: "\ue272"   // align-horizontal-justify-center
ALIGN_HORIZONTAL_JUSTIFY_END       :: "\ue273"   // align-horizontal-justify-end
ALIGN_HORIZONTAL_JUSTIFY_START     :: "\ue274"   // align-horizontal-justify-start
ALIGN_HORIZONTAL_SPACE_AROUND      :: "\ue275"   // align-horizontal-space-around
ALIGN_HORIZONTAL_SPACE_BETWEEN     :: "\ue276"   // align-horizontal-space-between
ALIGN_JUSTIFY                      :: "\ue184"   // align-justify
ALIGN_LEFT                         :: "\ue185"   // align-left
ALIGN_RIGHT                        :: "\ue183"   // align-right
ALIGN_START_HORIZONTAL             :: "\ue270"   // align-start-horizontal
ALIGN_START_VERTICAL               :: "\ue271"   // align-start-vertical
ALIGN_VERTICAL_DISTRIBUTE_CENTER   :: "\ue27e"   // align-vertical-distribute-center
ALIGN_VERTICAL_DISTRIBUTE_END      :: "\ue27f"   // align-vertical-distribute-end
ALIGN_VERTICAL_DISTRIBUTE_START    :: "\ue280"   // align-vertical-distribute-start
ALIGN_VERTICAL_JUSTIFY_CENTER      :: "\ue277"   // align-vertical-justify-center
ALIGN_VERTICAL_JUSTIFY_END         :: "\ue278"   // align-vertical-justify-end
ALIGN_VERTICAL_JUSTIFY_START       :: "\ue279"   // align-vertical-justify-start
ALIGN_VERTICAL_SPACE_AROUND        :: "\ue27a"   // align-vertical-space-around
ALIGN_VERTICAL_SPACE_BETWEEN       :: "\ue27b"   // align-vertical-space-between
AMBULANCE                          :: "\ue5bb"   // ambulance
AMPERSAND                          :: "\ue49c"   // ampersand
AMPERSANDS                         :: "\ue49d"   // ampersands
AMPHORA                            :: "\ue61b"   // amphora
ANCHOR                             :: "\ue03f"   // anchor
ANGLE                              :: "\ue732"   // angle
ANGRY                              :: "\ue2fc"   // angry
ANNOYED                            :: "\ue2fd"   // annoyed
ANTENNA                            :: "\ue4e2"   // antenna
ANVIL                              :: "\ue580"   // anvil
APERTURE                           :: "\ue040"   // aperture
APP_WINDOW                         :: "\ue426"   // app-window
APP_WINDOW_MAC                     :: "\ue5d2"   // app-window-mac
APPLE                              :: "\ue34e"   // apple
ARCHIVE                            :: "\ue041"   // archive
ARCHIVE_RESTORE                    :: "\ue2cd"   // archive-restore
ARCHIVE_X                          :: "\ue50c"   // archive-x
AREA_CHART                         :: "\ue4d3"   // area-chart
ARMCHAIR                           :: "\ue2c0"   // armchair
ARMENIAN_DRAM                      :: "\ue791"   // armenian-dram
ARROW_BIG_DOWN                     :: "\ue1e1"   // arrow-big-down
ARROW_BIG_DOWN_DASH                :: "\ue41d"   // arrow-big-down-dash
ARROW_BIG_LEFT                     :: "\ue1e2"   // arrow-big-left
ARROW_BIG_LEFT_DASH                :: "\ue41e"   // arrow-big-left-dash
ARROW_BIG_RIGHT                    :: "\ue1e3"   // arrow-big-right
ARROW_BIG_RIGHT_DASH               :: "\ue41f"   // arrow-big-right-dash
ARROW_BIG_UP                       :: "\ue1e4"   // arrow-big-up
ARROW_BIG_UP_DASH                  :: "\ue420"   // arrow-big-up-dash
ARROW_DOWN                         :: "\ue042"   // arrow-down
ARROW_DOWN_0_1                     :: "\ue413"   // arrow-down-0-1
ARROW_DOWN_1_0                     :: "\ue414"   // arrow-down-1-0
ARROW_DOWN_A_Z                     :: "\ue415"   // arrow-down-a-z
ARROW_DOWN_CIRCLE                  :: "\ue078"   // arrow-down-circle
ARROW_DOWN_FROM_LINE               :: "\ue454"   // arrow-down-from-line
ARROW_DOWN_LEFT                    :: "\ue043"   // arrow-down-left
ARROW_DOWN_LEFT_FROM_CIRCLE        :: "\ue3f7"   // arrow-down-left-from-circle
ARROW_DOWN_LEFT_FROM_SQUARE        :: "\ue5a1"   // arrow-down-left-from-square
ARROW_DOWN_LEFT_SQUARE             :: "\ue4b5"   // arrow-down-left-square
ARROW_DOWN_NARROW_WIDE             :: "\ue044"   // arrow-down-narrow-wide
ARROW_DOWN_RIGHT                   :: "\ue045"   // arrow-down-right
ARROW_DOWN_RIGHT_FROM_CIRCLE       :: "\ue3f8"   // arrow-down-right-from-circle
ARROW_DOWN_RIGHT_FROM_SQUARE       :: "\ue5a2"   // arrow-down-right-from-square
ARROW_DOWN_RIGHT_SQUARE            :: "\ue4b6"   // arrow-down-right-square
ARROW_DOWN_SQUARE                  :: "\ue427"   // arrow-down-square
ARROW_DOWN_TO_DOT                  :: "\ue44d"   // arrow-down-to-dot
ARROW_DOWN_TO_LINE                 :: "\ue455"   // arrow-down-to-line
ARROW_DOWN_UP                      :: "\ue046"   // arrow-down-up
ARROW_DOWN_WIDE_NARROW             :: "\ue047"   // arrow-down-wide-narrow
ARROW_DOWN_Z_A                     :: "\ue416"   // arrow-down-z-a
ARROW_LEFT                         :: "\ue048"   // arrow-left
ARROW_LEFT_CIRCLE                  :: "\ue079"   // arrow-left-circle
ARROW_LEFT_FROM_LINE               :: "\ue456"   // arrow-left-from-line
ARROW_LEFT_RIGHT                   :: "\ue24a"   // arrow-left-right
ARROW_LEFT_SQUARE                  :: "\ue428"   // arrow-left-square
ARROW_LEFT_TO_LINE                 :: "\ue457"   // arrow-left-to-line
ARROW_RIGHT                        :: "\ue049"   // arrow-right
ARROW_RIGHT_CIRCLE                 :: "\ue07a"   // arrow-right-circle
ARROW_RIGHT_FROM_LINE              :: "\ue458"   // arrow-right-from-line
ARROW_RIGHT_LEFT                   :: "\ue417"   // arrow-right-left
ARROW_RIGHT_SQUARE                 :: "\ue429"   // arrow-right-square
ARROW_RIGHT_TO_LINE                :: "\ue459"   // arrow-right-to-line
ARROW_UP                           :: "\ue04a"   // arrow-up
ARROW_UP_0_1                       :: "\ue418"   // arrow-up-0-1
ARROW_UP_1_0                       :: "\ue419"   // arrow-up-1-0
ARROW_UP_A_Z                       :: "\ue41a"   // arrow-up-a-z
ARROW_UP_CIRCLE                    :: "\ue07b"   // arrow-up-circle
ARROW_UP_DOWN                      :: "\ue37d"   // arrow-up-down
ARROW_UP_FROM_DOT                  :: "\ue44e"   // arrow-up-from-dot
ARROW_UP_FROM_LINE                 :: "\ue45a"   // arrow-up-from-line
ARROW_UP_LEFT                      :: "\ue04b"   // arrow-up-left
ARROW_UP_LEFT_FROM_CIRCLE          :: "\ue3f9"   // arrow-up-left-from-circle
ARROW_UP_LEFT_FROM_SQUARE          :: "\ue5a3"   // arrow-up-left-from-square
ARROW_UP_LEFT_SQUARE               :: "\ue4b7"   // arrow-up-left-square
ARROW_UP_NARROW_WIDE               :: "\ue04c"   // arrow-up-narrow-wide
ARROW_UP_RIGHT                     :: "\ue04d"   // arrow-up-right
ARROW_UP_RIGHT_FROM_CIRCLE         :: "\ue3fa"   // arrow-up-right-from-circle
ARROW_UP_RIGHT_FROM_SQUARE         :: "\ue5a4"   // arrow-up-right-from-square
ARROW_UP_RIGHT_SQUARE              :: "\ue4b8"   // arrow-up-right-square
ARROW_UP_SQUARE                    :: "\ue42a"   // arrow-up-square
ARROW_UP_TO_LINE                   :: "\ue45b"   // arrow-up-to-line
ARROW_UP_WIDE_NARROW               :: "\ue41b"   // arrow-up-wide-narrow
ARROW_UP_Z_A                       :: "\ue41c"   // arrow-up-z-a
ARROWS_UP_FROM_LINE                :: "\ue4d4"   // arrows-up-from-line
ASTERISK                           :: "\ue1ef"   // asterisk
ASTERISK_SQUARE                    :: "\ue168"   // asterisk-square
ASTROID                            :: "\ue6f0"   // astroid
AT_SIGN                            :: "\ue04e"   // at-sign
ATOM                               :: "\ue3d7"   // atom
AUDIO_LINES                        :: "\ue55a"   // audio-lines
AUDIO_LINES_OFF                    :: "\ue737"   // audio-lines-off
AUDIO_LINES_X                      :: "\ue72e"   // audio-lines-x
AUDIO_WAVEFORM                     :: "\ue55b"   // audio-waveform
AWARD                              :: "\ue04f"   // award
AXE                                :: "\ue050"   // axe
AXIS_3_D                           :: "\ue2fe"   // axis-3-d
BABY                               :: "\ue2ce"   // baby
BACKPACK                           :: "\ue2c8"   // backpack
BADGE                              :: "\ue474"   // badge
BADGE_ALERT                        :: "\ue475"   // badge-alert
BADGE_CENT                         :: "\ue50f"   // badge-cent
BADGE_CHECK                        :: "\ue241"   // badge-check
BADGE_DOLLAR_SIGN                  :: "\ue476"   // badge-dollar-sign
BADGE_EURO                         :: "\ue510"   // badge-euro
BADGE_HELP                         :: "\ue47b"   // badge-help
BADGE_INDIAN_RUPEE                 :: "\ue511"   // badge-indian-rupee
BADGE_INFO                         :: "\ue477"   // badge-info
BADGE_JAPANESE_YEN                 :: "\ue512"   // badge-japanese-yen
BADGE_MINUS                        :: "\ue478"   // badge-minus
BADGE_PERCENT                      :: "\ue479"   // badge-percent
BADGE_PLUS                         :: "\ue47a"   // badge-plus
BADGE_POUND_STERLING               :: "\ue513"   // badge-pound-sterling
BADGE_RUSSIAN_RUBLE                :: "\ue514"   // badge-russian-ruble
BADGE_SWISS_FRANC                  :: "\ue515"   // badge-swiss-franc
BADGE_TURKISH_LIRA                 :: "\ue67e"   // badge-turkish-lira
BADGE_X                            :: "\ue47c"   // badge-x
BAGGAGE_CLAIM                      :: "\ue2c9"   // baggage-claim
BALLOON                            :: "\ue6af"   // balloon
BAN                                :: "\ue051"   // ban
BANANA                             :: "\ue34f"   // banana
BANDAGE                            :: "\ue61d"   // bandage
BANGLADESHI_TAKA                   :: "\ue78d"   // bangladeshi-taka
BANKNOTE                           :: "\ue052"   // banknote
BANKNOTE_ARROW_DOWN                :: "\ue64c"   // banknote-arrow-down
BANKNOTE_ARROW_UP                  :: "\ue64d"   // banknote-arrow-up
BANKNOTE_CHECK                     :: "\ue70c"   // banknote-check
BANKNOTE_X                         :: "\ue64e"   // banknote-x
BAR_CHART                          :: "\ue06a"   // bar-chart
BAR_CHART_2                        :: "\ue068"   // bar-chart-2
BAR_CHART_3                        :: "\ue2a3"   // bar-chart-3
BAR_CHART_4                        :: "\ue2a4"   // bar-chart-4
BAR_CHART_BIG                      :: "\ue4a9"   // bar-chart-big
BAR_CHART_HORIZONTAL               :: "\ue2a2"   // bar-chart-horizontal
BAR_CHART_HORIZONTAL_BIG           :: "\ue4a7"   // bar-chart-horizontal-big
BARCODE                            :: "\ue533"   // barcode
BARREL                             :: "\ue675"   // barrel
BASELINE                           :: "\ue285"   // baseline
BATH                               :: "\ue2ab"   // bath
BATTERY                            :: "\ue053"   // battery
BATTERY_CHARGING                   :: "\ue054"   // battery-charging
BATTERY_FULL                       :: "\ue055"   // battery-full
BATTERY_LOW                        :: "\ue056"   // battery-low
BATTERY_MEDIUM                     :: "\ue057"   // battery-medium
BATTERY_PLUS                       :: "\ue63e"   // battery-plus
BATTERY_WARNING                    :: "\ue3ac"   // battery-warning
BEAKER                             :: "\ue058"   // beaker
BEAN                               :: "\ue38f"   // bean
BEAN_OFF                           :: "\ue390"   // bean-off
BED                                :: "\ue2c1"   // bed
BED_DOUBLE                         :: "\ue2c2"   // bed-double
BED_SINGLE                         :: "\ue2c3"   // bed-single
BEEF                               :: "\ue3a5"   // beef
BEEF_OFF                           :: "\ue6dc"   // beef-off
BEER                               :: "\ue2cf"   // beer
BEER_OFF                           :: "\ue5d9"   // beer-off
BELL                               :: "\ue059"   // bell
BELL_CHECK                         :: "\ue6ef"   // bell-check
BELL_DOT                           :: "\ue42b"   // bell-dot
BELL_ELECTRIC                      :: "\ue57c"   // bell-electric
BELL_MINUS                         :: "\ue1f0"   // bell-minus
BELL_OFF                           :: "\ue05a"   // bell-off
BELL_PLUS                          :: "\ue1f1"   // bell-plus
BELL_RING                          :: "\ue224"   // bell-ring
BETWEEN_HORIZONAL_END              :: "\ue591"   // between-horizonal-end
BETWEEN_HORIZONAL_START            :: "\ue592"   // between-horizonal-start
BETWEEN_VERTICAL_END               :: "\ue593"   // between-vertical-end
BETWEEN_VERTICAL_START             :: "\ue594"   // between-vertical-start
BICEPS_FLEXED                      :: "\ue5eb"   // biceps-flexed
BIKE                               :: "\ue1d2"   // bike
BINARY                             :: "\ue1f2"   // binary
BINOCULARS                         :: "\ue621"   // binoculars
BIOHAZARD                          :: "\ue441"   // biohazard
BIRD                               :: "\ue3c5"   // bird
BIRDHOUSE                          :: "\ue69a"   // birdhouse
BITCOIN                            :: "\ue05b"   // bitcoin
BLEND                              :: "\ue59c"   // blend
BLENDER                            :: "\ue6f4"   // blender
BLINDS                             :: "\ue3c0"   // blinds
BLOCKS                             :: "\ue4fa"   // blocks
BLUETOOTH                          :: "\ue05c"   // bluetooth
BLUETOOTH_CONNECTED                :: "\ue1b8"   // bluetooth-connected
BLUETOOTH_OFF                      :: "\ue1b9"   // bluetooth-off
BLUETOOTH_SEARCHING                :: "\ue1ba"   // bluetooth-searching
BOLD                               :: "\ue05d"   // bold
BOLT                               :: "\ue58c"   // bolt
BOMB                               :: "\ue2ff"   // bomb
BONE                               :: "\ue358"   // bone
BONE_FRACTURE                      :: "\ue715"   // bone-fracture
BOOK                               :: "\ue05e"   // book
BOOK_A                             :: "\ue544"   // book-a
BOOK_ALERT                         :: "\ue672"   // book-alert
BOOK_AUDIO                         :: "\ue545"   // book-audio
BOOK_BOOKMARK                      :: "\ue3f1"   // book-bookmark
BOOK_CHECK                         :: "\ue546"   // book-check
BOOK_COPY                          :: "\ue3ec"   // book-copy
BOOK_DASHED                        :: "\ue3ed"   // book-dashed
BOOK_DOWN                          :: "\ue3ee"   // book-down
BOOK_HEADPHONES                    :: "\ue547"   // book-headphones
BOOK_HEART                         :: "\ue548"   // book-heart
BOOK_IMAGE                         :: "\ue549"   // book-image
BOOK_KEY                           :: "\ue3ef"   // book-key
BOOK_LOCK                          :: "\ue3f0"   // book-lock
BOOK_MINUS                         :: "\ue3f2"   // book-minus
BOOK_OPEN                          :: "\ue05f"   // book-open
BOOK_OPEN_CHECK                    :: "\ue381"   // book-open-check
BOOK_OPEN_TEXT                     :: "\ue54a"   // book-open-text
BOOK_PLUS                          :: "\ue3f3"   // book-plus
BOOK_SEARCH                        :: "\ue6ab"   // book-search
BOOK_TEXT                          :: "\ue54b"   // book-text
BOOK_TYPE                          :: "\ue54c"   // book-type
BOOK_UP                            :: "\ue3f4"   // book-up
BOOK_UP_2                          :: "\ue4a6"   // book-up-2
BOOK_USER                          :: "\ue54d"   // book-user
BOOK_X                             :: "\ue3f5"   // book-x
BOOKMARK                           :: "\ue060"   // bookmark
BOOKMARK_CHECK                     :: "\ue51f"   // bookmark-check
BOOKMARK_MINUS                     :: "\ue23c"   // bookmark-minus
BOOKMARK_OFF                       :: "\ue6df"   // bookmark-off
BOOKMARK_PLUS                      :: "\ue23d"   // bookmark-plus
BOOKMARK_X                         :: "\ue520"   // bookmark-x
BOOM_BOX                           :: "\ue4ee"   // boom-box
BOT                                :: "\ue1bb"   // bot
BOT_MESSAGE_SQUARE                 :: "\ue5ce"   // bot-message-square
BOT_OFF                            :: "\ue5e0"   // bot-off
BOTTLE_WINE                        :: "\ue67b"   // bottle-wine
BOW_ARROW                          :: "\ue65e"   // bow-arrow
BOX                                :: "\ue061"   // box
BOX_SELECT                         :: "\ue1cb"   // box-select
BOXES                              :: "\ue2d0"   // boxes
BRACES                             :: "\ue36a"   // braces
BRACKETS                           :: "\ue443"   // brackets
BRAIN                              :: "\ue3c6"   // brain
BRAIN_CIRCUIT                      :: "\ue3c7"   // brain-circuit
BRAIN_COG                          :: "\ue3c8"   // brain-cog
BRICK_WALL                         :: "\ue581"   // brick-wall
BRICK_WALL_FIRE                    :: "\ue653"   // brick-wall-fire
BRICK_WALL_SHIELD                  :: "\ue690"   // brick-wall-shield
BRIDGE                             :: "\ue74f"   // bridge
BRIEFCASE                          :: "\ue062"   // briefcase
BRIEFCASE_BUSINESS                 :: "\ue5d5"   // briefcase-business
BRIEFCASE_CONVEYOR_BELT            :: "\ue62b"   // briefcase-conveyor-belt
BRIEFCASE_MEDICAL                  :: "\ue5d6"   // briefcase-medical
BRIEFCASE_PLUS                     :: "\ue787"   // briefcase-plus
BRING_TO_FRONT                     :: "\ue4ef"   // bring-to-front
BROCCOLI                           :: "\ue6f5"   // broccoli
BROOM                              :: "\ue730"   // broom
BROOM_SPARKLES                     :: "\ue72f"   // broom-sparkles
BRUSH                              :: "\ue1d3"   // brush
BRUSH_CLEANING                     :: "\ue666"   // brush-cleaning
BUBBLES                            :: "\ue654"   // bubbles
BUG                                :: "\ue20c"   // bug
BUG_OFF                            :: "\ue50d"   // bug-off
BUG_PLAY                           :: "\ue50e"   // bug-play
BUILDING                           :: "\ue1cc"   // building
BUILDING_2                         :: "\ue290"   // building-2
BUILDING_COMPLEX_PLUS              :: "\ue76b"   // building-complex-plus
BUS                                :: "\ue1d4"   // bus
BUS_FRONT                          :: "\ue4fb"   // bus-front
CABLE                              :: "\ue4e3"   // cable
CABLE_CAR                          :: "\ue4fc"   // cable-car
CAKE                               :: "\ue344"   // cake
CAKE_SLICE                         :: "\ue4b9"   // cake-slice
CALCULATOR                         :: "\ue1bc"   // calculator
CALENDAR                           :: "\ue063"   // calendar
CALENDAR_1                         :: "\ue630"   // calendar-1
CALENDAR_ARROW_DOWN                :: "\ue5fe"   // calendar-arrow-down
CALENDAR_ARROW_UP                  :: "\ue5ff"   // calendar-arrow-up
CALENDAR_CHECK                     :: "\ue2b7"   // calendar-check
CALENDAR_CHECK_2                   :: "\ue2b8"   // calendar-check-2
CALENDAR_CHEVRONS_RIGHT            :: "\ue76c"   // calendar-chevrons-right
CALENDAR_CLOCK                     :: "\ue304"   // calendar-clock
CALENDAR_COG                       :: "\ue5ed"   // calendar-cog
CALENDAR_DAYS                      :: "\ue2b9"   // calendar-days
CALENDAR_FOLD                      :: "\ue5b4"   // calendar-fold
CALENDAR_HEART                     :: "\ue305"   // calendar-heart
CALENDAR_MINUS                     :: "\ue2ba"   // calendar-minus
CALENDAR_MINUS_2                   :: "\ue5b5"   // calendar-minus-2
CALENDAR_OFF                       :: "\ue2bb"   // calendar-off
CALENDAR_PLUS                      :: "\ue2bc"   // calendar-plus
CALENDAR_PLUS_2                    :: "\ue5b6"   // calendar-plus-2
CALENDAR_RANGE                     :: "\ue2bd"   // calendar-range
CALENDAR_SEARCH                    :: "\ue306"   // calendar-search
CALENDAR_SYNC                      :: "\ue636"   // calendar-sync
CALENDAR_X                         :: "\ue2be"   // calendar-x
CALENDAR_X_2                       :: "\ue2bf"   // calendar-x-2
CALENDARS                          :: "\ue6a7"   // calendars
CAMERA                             :: "\ue064"   // camera
CAMERA_OFF                         :: "\ue065"   // camera-off
CAN                                :: "\ue750"   // can
CAN_SODA                           :: "\ue755"   // can-soda
CANDLESTICK_CHART                  :: "\ue4a8"   // candlestick-chart
CANDY                              :: "\ue391"   // candy
CANDY_CANE                         :: "\ue4ba"   // candy-cane
CANDY_OFF                          :: "\ue392"   // candy-off
CANNABIS                           :: "\ue5d4"   // cannabis
CANNABIS_OFF                       :: "\ue6e0"   // cannabis-off
CAPTIONS                           :: "\ue3a4"   // captions
CAPTIONS_OFF                       :: "\ue5c1"   // captions-off
CAR                                :: "\ue1d5"   // car
CAR_BATTERY                        :: "\ue735"   // car-battery
CAR_FRONT                          :: "\ue4fd"   // car-front
CAR_TAXI_FRONT                     :: "\ue4fe"   // car-taxi-front
CARAVAN                            :: "\ue539"   // caravan
CARD_SIM                           :: "\ue671"   // card-sim
CARROT                             :: "\ue25a"   // carrot
CARTON                             :: "\ue767"   // carton
CARTON_OFF                         :: "\ue766"   // carton-off
CASE_LOWER                         :: "\ue3d8"   // case-lower
CASE_SENSITIVE                     :: "\ue3d9"   // case-sensitive
CASE_UPPER                         :: "\ue3da"   // case-upper
CASSETTE_TAPE                      :: "\ue4ca"   // cassette-tape
CAST                               :: "\ue066"   // cast
CASTLE                             :: "\ue3e0"   // castle
CAT                                :: "\ue38c"   // cat
CCTV                               :: "\ue57d"   // cctv
CCTV_OFF                           :: "\ue6d8"   // cctv-off
CHART_BAR_DECREASING               :: "\ue607"   // chart-bar-decreasing
CHART_BAR_INCREASING               :: "\ue608"   // chart-bar-increasing
CHART_BAR_STACKED                  :: "\ue609"   // chart-bar-stacked
CHART_COLUMN_DECREASING            :: "\ue067"   // chart-column-decreasing
CHART_COLUMN_STACKED               :: "\ue60a"   // chart-column-stacked
CHART_GANTT                        :: "\ue624"   // chart-gantt
CHART_LINE                         :: "\ue2a5"   // chart-line
CHART_NETWORK                      :: "\ue60b"   // chart-network
CHART_NO_AXES_COLUMN_DECREASING    :: "\ue069"   // chart-no-axes-column-decreasing
CHART_NO_AXES_COMBINED             :: "\ue60c"   // chart-no-axes-combined
CHART_NO_AXES_GANTT                :: "\ue4c4"   // chart-no-axes-gantt
CHART_PIE                          :: "\ue06b"   // chart-pie
CHART_SCATTER                      :: "\ue48a"   // chart-scatter
CHART_SPLINE                       :: "\ue60d"   // chart-spline
CHECK                              :: "\ue06c"   // check
CHECK_CHECK                        :: "\ue38e"   // check-check
CHECK_CIRCLE                       :: "\ue07c"   // check-circle
CHECK_CIRCLE_2                     :: "\ue226"   // check-circle-2
CHECK_LINE                         :: "\ue66b"   // check-line
CHECK_SQUARE                       :: "\ue16a"   // check-square
CHECK_SQUARE_2                     :: "\ue559"   // check-square-2
CHEF_HAT                           :: "\ue2ac"   // chef-hat
CHERRY                             :: "\ue350"   // cherry
CHESS_BISHOP                       :: "\ue6a0"   // chess-bishop
CHESS_KING                         :: "\ue6a1"   // chess-king
CHESS_KNIGHT                       :: "\ue6a2"   // chess-knight
CHESS_PAWN                         :: "\ue6a3"   // chess-pawn
CHESS_QUEEN                        :: "\ue6a4"   // chess-queen
CHESS_ROOK                         :: "\ue6a5"   // chess-rook
CHEVRON_DOWN                       :: "\ue06d"   // chevron-down
CHEVRON_DOWN_CIRCLE                :: "\ue4dd"   // chevron-down-circle
CHEVRON_DOWN_SQUARE                :: "\ue3cf"   // chevron-down-square
CHEVRON_FIRST                      :: "\ue243"   // chevron-first
CHEVRON_LAST                       :: "\ue244"   // chevron-last
CHEVRON_LEFT                       :: "\ue06e"   // chevron-left
CHEVRON_LEFT_CIRCLE                :: "\ue4de"   // chevron-left-circle
CHEVRON_LEFT_SQUARE                :: "\ue3d0"   // chevron-left-square
CHEVRON_RIGHT                      :: "\ue06f"   // chevron-right
CHEVRON_RIGHT_CIRCLE               :: "\ue4df"   // chevron-right-circle
CHEVRON_RIGHT_SQUARE               :: "\ue3d1"   // chevron-right-square
CHEVRON_UP                         :: "\ue070"   // chevron-up
CHEVRON_UP_CIRCLE                  :: "\ue4e0"   // chevron-up-circle
CHEVRON_UP_SQUARE                  :: "\ue3d2"   // chevron-up-square
CHEVRONS_DOWN                      :: "\ue071"   // chevrons-down
CHEVRONS_DOWN_UP                   :: "\ue228"   // chevrons-down-up
CHEVRONS_LEFT                      :: "\ue072"   // chevrons-left
CHEVRONS_LEFT_RIGHT                :: "\ue293"   // chevrons-left-right
CHEVRONS_LEFT_RIGHT_ELLIPSIS       :: "\ue61f"   // chevrons-left-right-ellipsis
CHEVRONS_RIGHT                     :: "\ue073"   // chevrons-right
CHEVRONS_RIGHT_LEFT                :: "\ue294"   // chevrons-right-left
CHEVRONS_UP                        :: "\ue074"   // chevrons-up
CHEVRONS_UP_DOWN                   :: "\ue211"   // chevrons-up-down
CHURCH                             :: "\ue3e1"   // church
CIGARETTE                          :: "\ue2c6"   // cigarette
CIGARETTE_OFF                      :: "\ue2c7"   // cigarette-off
CIRCLE                             :: "\ue076"   // circle
CIRCLE_DASHED                      :: "\ue4b0"   // circle-dashed
CIRCLE_DASHED_CHECK                :: "\ue75e"   // circle-dashed-check
CIRCLE_DIVIDE                      :: "\ue07d"   // circle-divide
CIRCLE_DOLLAR_SIGN                 :: "\ue47d"   // circle-dollar-sign
CIRCLE_DOT                         :: "\ue345"   // circle-dot
CIRCLE_DOT_DASHED                  :: "\ue4b1"   // circle-dot-dashed
CIRCLE_ELLIPSIS                    :: "\ue346"   // circle-ellipsis
CIRCLE_EQUAL                       :: "\ue400"   // circle-equal
CIRCLE_EURO                        :: "\ue71f"   // circle-euro
CIRCLE_FADING_ARROW_UP             :: "\ue618"   // circle-fading-arrow-up
CIRCLE_FADING_PLUS                 :: "\ue5bc"   // circle-fading-plus
CIRCLE_GAUGE                       :: "\ue4e1"   // circle-gauge
CIRCLE_HELP                        :: "\ue082"   // circle-help
CIRCLE_MINUS                       :: "\ue07e"   // circle-minus
CIRCLE_OFF                         :: "\ue401"   // circle-off
CIRCLE_PARKING                     :: "\ue3c9"   // circle-parking
CIRCLE_PARKING_OFF                 :: "\ue3ca"   // circle-parking-off
CIRCLE_PAUSE                       :: "\ue07f"   // circle-pause
CIRCLE_PERCENT                     :: "\ue51a"   // circle-percent
CIRCLE_PILE                        :: "\ue6e1"   // circle-pile
CIRCLE_PLAY                        :: "\ue080"   // circle-play
CIRCLE_PLUS                        :: "\ue081"   // circle-plus
CIRCLE_POUND_STERLING              :: "\ue66d"   // circle-pound-sterling
CIRCLE_POWER                       :: "\ue550"   // circle-power
CIRCLE_SLASH                       :: "\ue402"   // circle-slash
CIRCLE_SLASH_2                     :: "\ue213"   // circle-slash-2
CIRCLE_SMALL                       :: "\ue640"   // circle-small
CIRCLE_STAR                        :: "\ue68d"   // circle-star
CIRCLE_STOP                        :: "\ue083"   // circle-stop
CIRCLE_USER                        :: "\ue461"   // circle-user
CIRCLE_USER_ROUND                  :: "\ue462"   // circle-user-round
CIRCLE_X                           :: "\ue084"   // circle-x
CIRCUIT_BOARD                      :: "\ue403"   // circuit-board
CITRUS                             :: "\ue375"   // citrus
CLAPPERBOARD                       :: "\ue29b"   // clapperboard
CLEF_ALTO                          :: "\ue779"   // clef-alto
CLEF_BASS                          :: "\ue77a"   // clef-bass
CLEF_TREBLE                        :: "\ue77b"   // clef-treble
CLIPBOARD                          :: "\ue085"   // clipboard
CLIPBOARD_CHECK                    :: "\ue219"   // clipboard-check
CLIPBOARD_CLOCK                    :: "\ue688"   // clipboard-clock
CLIPBOARD_COPY                     :: "\ue225"   // clipboard-copy
CLIPBOARD_EDIT                     :: "\ue307"   // clipboard-edit
CLIPBOARD_LIST                     :: "\ue086"   // clipboard-list
CLIPBOARD_MINUS                    :: "\ue5be"   // clipboard-minus
CLIPBOARD_PASTE                    :: "\ue3e8"   // clipboard-paste
CLIPBOARD_PEN_LINE                 :: "\ue308"   // clipboard-pen-line
CLIPBOARD_PLUS                     :: "\ue5bf"   // clipboard-plus
CLIPBOARD_TYPE                     :: "\ue309"   // clipboard-type
CLIPBOARD_X                        :: "\ue222"   // clipboard-x
CLOCK_1                            :: "\ue24b"   // clock-1
CLOCK_10                           :: "\ue24c"   // clock-10
CLOCK_11                           :: "\ue24d"   // clock-11
CLOCK_12                           :: "\ue24e"   // clock-12
CLOCK_2                            :: "\ue24f"   // clock-2
CLOCK_3                            :: "\ue250"   // clock-3
CLOCK_4                            :: "\ue087"   // clock-4
CLOCK_5                            :: "\ue252"   // clock-5
CLOCK_6                            :: "\ue253"   // clock-6
CLOCK_7                            :: "\ue254"   // clock-7
CLOCK_8                            :: "\ue255"   // clock-8
CLOCK_9                            :: "\ue256"   // clock-9
CLOCK_ALERT                        :: "\ue62a"   // clock-alert
CLOCK_ARROW_DOWN                   :: "\ue600"   // clock-arrow-down
CLOCK_ARROW_LEFT                   :: "\ue70d"   // clock-arrow-left
CLOCK_ARROW_RIGHT                  :: "\ue70e"   // clock-arrow-right
CLOCK_ARROW_UP                     :: "\ue601"   // clock-arrow-up
CLOCK_CHECK                        :: "\ue69e"   // clock-check
CLOCK_FADING                       :: "\ue64a"   // clock-fading
CLOCK_PLUS                         :: "\ue667"   // clock-plus
CLOSED_CAPTION                     :: "\ue68a"   // closed-caption
CLOUD                              :: "\ue088"   // cloud
CLOUD_ALERT                        :: "\ue633"   // cloud-alert
CLOUD_BACKUP                       :: "\ue6e2"   // cloud-backup
CLOUD_CHECK                        :: "\ue66e"   // cloud-check
CLOUD_COG                          :: "\ue30a"   // cloud-cog
CLOUD_DOWNLOAD                     :: "\ue089"   // cloud-download
CLOUD_DRIZZLE                      :: "\ue08a"   // cloud-drizzle
CLOUD_FOG                          :: "\ue214"   // cloud-fog
CLOUD_HAIL                         :: "\ue08b"   // cloud-hail
CLOUD_LIGHTNING                    :: "\ue08c"   // cloud-lightning
CLOUD_MOON                         :: "\ue215"   // cloud-moon
CLOUD_MOON_RAIN                    :: "\ue2fa"   // cloud-moon-rain
CLOUD_OFF                          :: "\ue08d"   // cloud-off
CLOUD_RAIN                         :: "\ue08e"   // cloud-rain
CLOUD_RAIN_WIND                    :: "\ue08f"   // cloud-rain-wind
CLOUD_SNOW                         :: "\ue090"   // cloud-snow
CLOUD_SUN                          :: "\ue216"   // cloud-sun
CLOUD_SUN_RAIN                     :: "\ue2fb"   // cloud-sun-rain
CLOUD_SYNC                         :: "\ue6e3"   // cloud-sync
CLOUD_UPLOAD                       :: "\ue091"   // cloud-upload
CLOUDY                             :: "\ue217"   // cloudy
CLOVER                             :: "\ue092"   // clover
CLUB                               :: "\ue496"   // club
CODE                               :: "\ue093"   // code
CODE_2                             :: "\ue206"   // code-2
CODE_SQUARE                        :: "\ue16b"   // code-square
COFFEE                             :: "\ue096"   // coffee
COG                                :: "\ue30b"   // cog
COINS                              :: "\ue097"   // coins
COLUMNS_2                          :: "\ue098"   // columns-2
COLUMNS_3                          :: "\ue099"   // columns-3
COLUMNS_3_COG                      :: "\ue661"   // columns-3-cog
COLUMNS_4                          :: "\ue589"   // columns-4
COMBINE                            :: "\ue44c"   // combine
COMMAND                            :: "\ue09a"   // command
COMPASS                            :: "\ue09b"   // compass
COMPONENT                          :: "\ue2ad"   // component
COMPUTER                           :: "\ue4e4"   // computer
CONCIERGE_BELL                     :: "\ue378"   // concierge-bell
CONE                               :: "\ue523"   // cone
CONSTRUCTION                       :: "\ue3b4"   // construction
CONTACT                            :: "\ue09c"   // contact
CONTACT_2                          :: "\ue463"   // contact-2
CONTAINER                          :: "\ue4d5"   // container
CONTRAST                           :: "\ue09d"   // contrast
COOKIE                             :: "\ue26b"   // cookie
COOKING_POT                        :: "\ue584"   // cooking-pot
COPY                               :: "\ue09e"   // copy
COPY_CHECK                         :: "\ue3fb"   // copy-check
COPY_MINUS                         :: "\ue3fc"   // copy-minus
COPY_PLUS                          :: "\ue3fd"   // copy-plus
COPY_SLASH                         :: "\ue3fe"   // copy-slash
COPY_X                             :: "\ue3ff"   // copy-x
COPYLEFT                           :: "\ue09f"   // copyleft
COPYRIGHT                          :: "\ue0a0"   // copyright
CORNER_DOWN_LEFT                   :: "\ue0a1"   // corner-down-left
CORNER_DOWN_RIGHT                  :: "\ue0a2"   // corner-down-right
CORNER_LEFT_DOWN                   :: "\ue0a3"   // corner-left-down
CORNER_LEFT_UP                     :: "\ue0a4"   // corner-left-up
CORNER_RIGHT_DOWN                  :: "\ue0a5"   // corner-right-down
CORNER_RIGHT_UP                    :: "\ue0a6"   // corner-right-up
CORNER_UP_LEFT                     :: "\ue0a7"   // corner-up-left
CORNER_UP_RIGHT                    :: "\ue0a8"   // corner-up-right
CPU                                :: "\ue0a9"   // cpu
CREATIVE_COMMONS                   :: "\ue3b2"   // creative-commons
CREDIT_CARD                        :: "\ue0aa"   // credit-card
CREDIT_CARD_CHECK                  :: "\ue743"   // credit-card-check
CREDIT_CARD_MINUS                  :: "\ue744"   // credit-card-minus
CREDIT_CARD_PLUS                   :: "\ue74b"   // credit-card-plus
CREDIT_CARD_READER                 :: "\ue756"   // credit-card-reader
CREDIT_CARD_X                      :: "\ue745"   // credit-card-x
CROISSANT                          :: "\ue2ae"   // croissant
CROP                               :: "\ue0ab"   // crop
CROSS                              :: "\ue1e5"   // cross
CROSSHAIR                          :: "\ue0ac"   // crosshair
CROWN                              :: "\ue1d6"   // crown
CUBOID                             :: "\ue524"   // cuboid
CUP_SODA                           :: "\ue2d1"   // cup-soda
CUPCAKE                            :: "\ue77d"   // cupcake
CURRENCY                           :: "\ue230"   // currency
CYLINDER                           :: "\ue525"   // cylinder
DAM                                :: "\ue606"   // dam
DATABASE                           :: "\ue0ad"   // database
DATABASE_ARROW_DOWN                :: "\ue716"   // database-arrow-down
DATABASE_ARROW_UP                  :: "\ue717"   // database-arrow-up
DATABASE_BACKUP                    :: "\ue3ab"   // database-backup
DATABASE_CHECK                     :: "\ue718"   // database-check
DATABASE_MINUS                     :: "\ue719"   // database-minus
DATABASE_PLUS                      :: "\ue71a"   // database-plus
DATABASE_SEARCH                    :: "\ue6b1"   // database-search
DATABASE_X                         :: "\ue71b"   // database-x
DATABASE_ZAP                       :: "\ue50b"   // database-zap
DECIMALS_ARROW_LEFT                :: "\ue65c"   // decimals-arrow-left
DECIMALS_ARROW_RIGHT               :: "\ue65d"   // decimals-arrow-right
DELETE                             :: "\ue0ae"   // delete
DESSERT                            :: "\ue4bb"   // dessert
DIAMETER                           :: "\ue526"   // diameter
DIAMOND                            :: "\ue2d2"   // diamond
DIAMOND_MINUS                      :: "\ue5e1"   // diamond-minus
DIAMOND_PERCENT                    :: "\ue51b"   // diamond-percent
DIAMOND_PLUS                       :: "\ue5e2"   // diamond-plus
DICE_1                             :: "\ue287"   // dice-1
DICE_2                             :: "\ue288"   // dice-2
DICE_3                             :: "\ue289"   // dice-3
DICE_4                             :: "\ue28a"   // dice-4
DICE_5                             :: "\ue28b"   // dice-5
DICE_6                             :: "\ue28c"   // dice-6
DICES                              :: "\ue2c5"   // dices
DIFF                               :: "\ue30c"   // diff
DISC                               :: "\ue0af"   // disc
DISC_2                             :: "\ue3f6"   // disc-2
DISC_3                             :: "\ue494"   // disc-3
DISC_ALBUM                         :: "\ue55c"   // disc-album
DIVIDE                             :: "\ue0b0"   // divide
DIVIDE_SQUARE                      :: "\ue16d"   // divide-square
DNA                                :: "\ue393"   // dna
DNA_OFF                            :: "\ue394"   // dna-off
DOCK                               :: "\ue5d3"   // dock
DOG                                :: "\ue38d"   // dog
DOLLAR_SIGN                        :: "\ue0b1"   // dollar-sign
DOME                               :: "\ue75f"   // dome
DONUT                              :: "\ue4bc"   // donut
DOOR_CLOSED                        :: "\ue3d5"   // door-closed
DOOR_CLOSED_COG                    :: "\ue792"   // door-closed-cog
DOOR_CLOSED_LOCKED                 :: "\ue664"   // door-closed-locked
DOOR_CLOSED_PACKAGE                :: "\ue77e"   // door-closed-package
DOOR_OPEN                          :: "\ue3d6"   // door-open
DOOR_STAIRWELL                     :: "\ue757"   // door-stairwell
DOT                                :: "\ue44f"   // dot
DOT_SQUARE                         :: "\ue16e"   // dot-square
DOWNLOAD                           :: "\ue0b2"   // download
DRAFTING_COMPASS                   :: "\ue527"   // drafting-compass
DRAMA                              :: "\ue521"   // drama
DRILL                              :: "\ue58d"   // drill
DRONE                              :: "\ue676"   // drone
DROPLET                            :: "\ue0b4"   // droplet
DROPLET_OFF                        :: "\ue638"   // droplet-off
DROPLETS                           :: "\ue0b5"   // droplets
DRUM                               :: "\ue55d"   // drum
DRUMSTICK                          :: "\ue25b"   // drumstick
DUMBBELL                           :: "\ue3a1"   // dumbbell
EAR                                :: "\ue382"   // ear
EAR_OFF                            :: "\ue383"   // ear-off
EARTH                              :: "\ue1f3"   // earth
EARTH_LOCK                         :: "\ue5cc"   // earth-lock
ECLIPSE                            :: "\ue59d"   // eclipse
EDIT                               :: "\ue172"   // edit
EDIT_2                             :: "\ue12f"   // edit-2
EDIT_3                             :: "\ue130"   // edit-3
EGG                                :: "\ue25d"   // egg
EGG_FRIED                          :: "\ue351"   // egg-fried
EGG_OFF                            :: "\ue395"   // egg-off
EJECT                              :: "\ue733"   // eject
ELLIPSE                            :: "\ue6b2"   // ellipse
ELLIPSIS                           :: "\ue0b6"   // ellipsis
ELLIPSIS_VERTICAL                  :: "\ue0b7"   // ellipsis-vertical
ENGINE                             :: "\ue758"   // engine
EQUAL                              :: "\ue1bd"   // equal
EQUAL_APPROXIMATELY                :: "\ue634"   // equal-approximately
EQUAL_APPROXIMATELY_NOT            :: "\ue760"   // equal-approximately-not
EQUAL_NOT                          :: "\ue1be"   // equal-not
EQUAL_SQUARE                       :: "\ue16f"   // equal-square
ERASER                             :: "\ue28f"   // eraser
ETHERNET_PORT                      :: "\ue620"   // ethernet-port
EURO                               :: "\ue0b8"   // euro
EV_CHARGER                         :: "\ue697"   // ev-charger
EXPAND                             :: "\ue21a"   // expand
EXTERNAL_LINK                      :: "\ue0b9"   // external-link
EYE                                :: "\ue0ba"   // eye
EYE_CLOSED                         :: "\ue62e"   // eye-closed
EYE_DASHED                         :: "\ue701"   // eye-dashed
EYE_OFF                            :: "\ue0bb"   // eye-off
FACE_GRINNING                      :: "\ue300"   // face-grinning
FACE_NEUTRAL                       :: "\ue114"   // face-neutral
FACE_SLIGHTLY_FROWNING             :: "\ue0db"   // face-slightly-frowning
FACE_SLIGHTLY_SMILING              :: "\ue164"   // face-slightly-smiling
FACE_SLIGHTLY_SMILING_PLUS         :: "\ue301"   // face-slightly-smiling-plus
FACTORY                            :: "\ue29f"   // factory
FAN                                :: "\ue379"   // fan
FAST_FORWARD                       :: "\ue0bd"   // fast-forward
FAUCET                             :: "\ue77f"   // faucet
FEATHER                            :: "\ue0be"   // feather
FENCE                              :: "\ue582"   // fence
FERRIS_WHEEL                       :: "\ue47f"   // ferris-wheel
FILE                               :: "\ue0c0"   // file
FILE_ARCHIVE                       :: "\ue30d"   // file-archive
FILE_AUDIO_2                       :: "\ue31a"   // file-audio-2
FILE_AXIS_3_D                      :: "\ue30e"   // file-axis-3-d
FILE_BADGE_2                       :: "\ue30f"   // file-badge-2
FILE_BAR_CHART                     :: "\ue312"   // file-bar-chart
FILE_BAR_CHART_2                   :: "\ue311"   // file-bar-chart-2
FILE_BOX                           :: "\ue310"   // file-box
FILE_BRACES                        :: "\ue36b"   // file-braces
FILE_BRACES_CORNER                 :: "\ue36c"   // file-braces-corner
FILE_CHART_LINE                    :: "\ue313"   // file-chart-line
FILE_CHART_PIE                     :: "\ue314"   // file-chart-pie
FILE_CHECK                         :: "\ue0c1"   // file-check
FILE_CHECK_2                       :: "\ue0c2"   // file-check-2
FILE_CLOCK                         :: "\ue315"   // file-clock
FILE_CODE                          :: "\ue0c3"   // file-code
FILE_CODE_2                        :: "\ue45e"   // file-code-2
FILE_COG_2                         :: "\ue316"   // file-cog-2
FILE_DIFF                          :: "\ue317"   // file-diff
FILE_DIGIT                         :: "\ue0c4"   // file-digit
FILE_DOWN                          :: "\ue318"   // file-down
FILE_EDIT                          :: "\ue31f"   // file-edit
FILE_EXCLAMATION_POINT             :: "\ue319"   // file-exclamation-point
FILE_HEART                         :: "\ue31b"   // file-heart
FILE_IMAGE                         :: "\ue31c"   // file-image
FILE_INPUT                         :: "\ue0c5"   // file-input
FILE_KEY_2                         :: "\ue31d"   // file-key-2
FILE_LOCK_2                        :: "\ue31e"   // file-lock-2
FILE_MINUS                         :: "\ue0c6"   // file-minus
FILE_MINUS_2                       :: "\ue0c7"   // file-minus-2
FILE_MUSIC                         :: "\ue55e"   // file-music
FILE_OUTPUT                        :: "\ue0c8"   // file-output
FILE_PEN_LINE                      :: "\ue320"   // file-pen-line
FILE_PLAY                          :: "\ue321"   // file-play
FILE_PLUS                          :: "\ue0c9"   // file-plus
FILE_PLUS_2                        :: "\ue0ca"   // file-plus-2
FILE_QUESTION_MARK                 :: "\ue322"   // file-question-mark
FILE_SCAN                          :: "\ue323"   // file-scan
FILE_SEARCH                        :: "\ue0cb"   // file-search
FILE_SEARCH_2                      :: "\ue324"   // file-search-2
FILE_SIGNAL                        :: "\ue325"   // file-signal
FILE_SLIDERS                       :: "\ue5a0"   // file-sliders
FILE_SPREADSHEET                   :: "\ue326"   // file-spreadsheet
FILE_STACK                         :: "\ue4a1"   // file-stack
FILE_SYMLINK                       :: "\ue327"   // file-symlink
FILE_TERMINAL                      :: "\ue328"   // file-terminal
FILE_TEXT                          :: "\ue0cc"   // file-text
FILE_TYPE                          :: "\ue329"   // file-type
FILE_TYPE_2                        :: "\ue36d"   // file-type-2
FILE_UP                            :: "\ue32a"   // file-up
FILE_USER                          :: "\ue62d"   // file-user
FILE_VIDEO_2                       :: "\ue32b"   // file-video-2
FILE_VOLUME                        :: "\ue32c"   // file-volume
FILE_X                             :: "\ue0cd"   // file-x
FILE_X_2                           :: "\ue0ce"   // file-x-2
FILES                              :: "\ue0cf"   // files
FILM                               :: "\ue0d0"   // film
FILTER                             :: "\ue0dc"   // filter
FILTER_X                           :: "\ue3b5"   // filter-x
FINGERPRINT_PATTERN                :: "\ue2cb"   // fingerprint-pattern
FIRE_EXTINGUISHER                  :: "\ue57e"   // fire-extinguisher
FISH                               :: "\ue3a6"   // fish
FISH_OFF                           :: "\ue3b0"   // fish-off
FISH_SYMBOL                        :: "\ue4f4"   // fish-symbol
FISHING_HOOK                       :: "\ue6e4"   // fishing-hook
FISHING_ROD                        :: "\ue6b3"   // fishing-rod
FLAG                               :: "\ue0d1"   // flag
FLAG_OFF                           :: "\ue292"   // flag-off
FLAG_TRIANGLE_LEFT                 :: "\ue237"   // flag-triangle-left
FLAG_TRIANGLE_RIGHT                :: "\ue238"   // flag-triangle-right
FLAME                              :: "\ue0d2"   // flame
FLAME_KINDLING                     :: "\ue53a"   // flame-kindling
FLASHLIGHT                         :: "\ue0d3"   // flashlight
FLASHLIGHT_OFF                     :: "\ue0d4"   // flashlight-off
FLASK_CONICAL                      :: "\ue0d5"   // flask-conical
FLASK_CONICAL_OFF                  :: "\ue396"   // flask-conical-off
FLASK_ROUND                        :: "\ue0d6"   // flask-round
FLIP_HORIZONTAL                    :: "\ue35d"   // flip-horizontal
FLIP_HORIZONTAL_2                  :: "\ue35e"   // flip-horizontal-2
FLIP_VERTICAL                      :: "\ue35f"   // flip-vertical
FLIP_VERTICAL_2                    :: "\ue360"   // flip-vertical-2
FLOWER                             :: "\ue2d3"   // flower
FLOWER_2                           :: "\ue2d4"   // flower-2
FOCUS                              :: "\ue29e"   // focus
FOLD_HORIZONTAL                    :: "\ue43b"   // fold-horizontal
FOLD_VERTICAL                      :: "\ue43c"   // fold-vertical
FOLDER                             :: "\ue0d7"   // folder
FOLDER_ARCHIVE                     :: "\ue32d"   // folder-archive
FOLDER_BOOKMARK                    :: "\ue6f1"   // folder-bookmark
FOLDER_CHECK                       :: "\ue32e"   // folder-check
FOLDER_CLOCK                       :: "\ue32f"   // folder-clock
FOLDER_CLOSED                      :: "\ue330"   // folder-closed
FOLDER_CODE                        :: "\ue5fb"   // folder-code
FOLDER_COG_2                       :: "\ue331"   // folder-cog-2
FOLDER_DOT                         :: "\ue4c5"   // folder-dot
FOLDER_DOWN                        :: "\ue332"   // folder-down
FOLDER_EDIT                        :: "\ue338"   // folder-edit
FOLDER_GIT                         :: "\ue409"   // folder-git
FOLDER_GIT_2                       :: "\ue40a"   // folder-git-2
FOLDER_HEART                       :: "\ue333"   // folder-heart
FOLDER_INPUT                       :: "\ue334"   // folder-input
FOLDER_KANBAN                      :: "\ue4c6"   // folder-kanban
FOLDER_KEY                         :: "\ue335"   // folder-key
FOLDER_LOCK                        :: "\ue336"   // folder-lock
FOLDER_MINUS                       :: "\ue0d8"   // folder-minus
FOLDER_OPEN                        :: "\ue247"   // folder-open
FOLDER_OPEN_DOT                    :: "\ue4c7"   // folder-open-dot
FOLDER_OUTPUT                      :: "\ue337"   // folder-output
FOLDER_PLUS                        :: "\ue0d9"   // folder-plus
FOLDER_ROOT                        :: "\ue4c8"   // folder-root
FOLDER_SEARCH                      :: "\ue339"   // folder-search
FOLDER_SEARCH_2                    :: "\ue33a"   // folder-search-2
FOLDER_SYMLINK                     :: "\ue33b"   // folder-symlink
FOLDER_SYNC                        :: "\ue4c9"   // folder-sync
FOLDER_TREE                        :: "\ue33c"   // folder-tree
FOLDER_UP                          :: "\ue33d"   // folder-up
FOLDER_X                           :: "\ue33e"   // folder-x
FOLDERS                            :: "\ue33f"   // folders
FOOTPRINTS                         :: "\ue3b9"   // footprints
FORK_KNIFE                         :: "\ue2f6"   // fork-knife
FORK_KNIFE_CROSSED                 :: "\ue2f7"   // fork-knife-crossed
FORKLIFT                           :: "\ue3c1"   // forklift
FORM                               :: "\ue6a8"   // form
FORM_INPUT                         :: "\ue21f"   // form-input
FORWARD                            :: "\ue229"   // forward
FRAME                              :: "\ue291"   // frame
FUEL                               :: "\ue2af"   // fuel
FULLSCREEN                         :: "\ue534"   // fullscreen
FUNCTION_SQUARE                    :: "\ue22d"   // function-square
FUNNEL_PLUS                        :: "\ue0dd"   // funnel-plus
GALAXY                             :: "\ue73f"   // galaxy
GALLERY_HORIZONTAL                 :: "\ue4ce"   // gallery-horizontal
GALLERY_HORIZONTAL_END             :: "\ue4cf"   // gallery-horizontal-end
GALLERY_THUMBNAILS                 :: "\ue4d0"   // gallery-thumbnails
GALLERY_VERTICAL                   :: "\ue4d1"   // gallery-vertical
GALLERY_VERTICAL_END               :: "\ue4d2"   // gallery-vertical-end
GAMEPAD                            :: "\ue0de"   // gamepad
GAMEPAD_2                          :: "\ue0df"   // gamepad-2
GAMEPAD_DIRECTIONAL                :: "\ue69b"   // gamepad-directional
GANTT_CHART_SQUARE                 :: "\ue169"   // gantt-chart-square
GAP_HORIZONTAL                     :: "\ue761"   // gap-horizontal
GAP_VERTICAL                       :: "\ue762"   // gap-vertical
GAUGE                              :: "\ue1bf"   // gauge
GAVEL                              :: "\ue0e0"   // gavel
GEM                                :: "\ue242"   // gem
GEORGIAN_LARI                      :: "\ue678"   // georgian-lari
GERM                               :: "\ue75a"   // germ
GERM_OFF                           :: "\ue759"   // germ-off
GHOST                              :: "\ue20e"   // ghost
GIFT                               :: "\ue0e1"   // gift
GIT_BRANCH                         :: "\ue0e2"   // git-branch
GIT_BRANCH_MINUS                   :: "\ue69c"   // git-branch-minus
GIT_BRANCH_PLUS                    :: "\ue1f4"   // git-branch-plus
GIT_COMMIT_HORIZONTAL              :: "\ue0e3"   // git-commit-horizontal
GIT_COMMIT_VERTICAL                :: "\ue552"   // git-commit-vertical
GIT_COMPARE                        :: "\ue359"   // git-compare
GIT_COMPARE_ARROWS                 :: "\ue553"   // git-compare-arrows
GIT_FORK                           :: "\ue28d"   // git-fork
GIT_GRAPH                          :: "\ue554"   // git-graph
GIT_MERGE                          :: "\ue0e4"   // git-merge
GIT_MERGE_CONFLICT                 :: "\ue6b4"   // git-merge-conflict
GIT_PULL_REQUEST                   :: "\ue0e5"   // git-pull-request
GIT_PULL_REQUEST_ARROW             :: "\ue555"   // git-pull-request-arrow
GIT_PULL_REQUEST_CLOSED            :: "\ue35a"   // git-pull-request-closed
GIT_PULL_REQUEST_CREATE            :: "\ue556"   // git-pull-request-create
GIT_PULL_REQUEST_CREATE_ARROW      :: "\ue557"   // git-pull-request-create-arrow
GIT_PULL_REQUEST_DRAFT             :: "\ue35b"   // git-pull-request-draft
GLASS_WATER                        :: "\ue2d5"   // glass-water
GLASSES                            :: "\ue20d"   // glasses
GLOBE                              :: "\ue0e8"   // globe
GLOBE_CHECK                        :: "\ue6fc"   // globe-check
GLOBE_CODE                         :: "\ue76d"   // globe-code
GLOBE_LOCK                         :: "\ue5cd"   // globe-lock
GLOBE_OFF                          :: "\ue6b5"   // globe-off
GLOBE_X                            :: "\ue6b6"   // globe-x
GOAL                               :: "\ue4a5"   // goal
GPU                                :: "\ue66a"   // gpu
GRAB                               :: "\ue1e6"   // grab
GRADUATION_CAP                     :: "\ue234"   // graduation-cap
GRAPE                              :: "\ue352"   // grape
GRID_2_X_2                         :: "\ue4ff"   // grid-2-x-2
GRID_2_X_2_CHECK                   :: "\ue5e4"   // grid-2-x-2-check
GRID_2_X_2_PLUS                    :: "\ue628"   // grid-2-x-2-plus
GRID_2_X_2_X                       :: "\ue5e5"   // grid-2-x-2-x
GRID_3_X_3                         :: "\ue0e9"   // grid-3-x-3
GRID_3X2                           :: "\ue66f"   // grid-3x2
GRIP                               :: "\ue3b1"   // grip
GRIP_HORIZONTAL                    :: "\ue0ea"   // grip-horizontal
GRIP_VERTICAL                      :: "\ue0eb"   // grip-vertical
GROCERIES                          :: "\ue799"   // groceries
GROUP                              :: "\ue464"   // group
GUITAR                             :: "\ue55f"   // guitar
HAM                                :: "\ue5d7"   // ham
HAMBURGER                          :: "\ue665"   // hamburger
HAMMER                             :: "\ue0ec"   // hammer
HAND                               :: "\ue1d7"   // hand
HAND_COINS                         :: "\ue5b8"   // hand-coins
HAND_FIST                          :: "\ue68b"   // hand-fist
HAND_HEART                         :: "\ue5b9"   // hand-heart
HAND_HELPING                       :: "\ue3b8"   // hand-helping
HAND_METAL                         :: "\ue22c"   // hand-metal
HAND_PLATTER                       :: "\ue5ba"   // hand-platter
HANDBAG                            :: "\ue689"   // handbag
HANDLE_BOTTOM_RIGHT                :: "\ue79d"   // handle-bottom-right
HANDSHAKE                          :: "\ue5c0"   // handshake
HARD_DRIVE                         :: "\ue0ed"   // hard-drive
HARD_DRIVE_DOWNLOAD                :: "\ue4e5"   // hard-drive-download
HARD_DRIVE_UPLOAD                  :: "\ue4e6"   // hard-drive-upload
HARD_HAT                           :: "\ue0ee"   // hard-hat
HASH                               :: "\ue0ef"   // hash
HAT_GLASSES                        :: "\ue683"   // hat-glasses
HAZE                               :: "\ue0f0"   // haze
HD                                 :: "\ue6e5"   // hd
HDMI_PORT                          :: "\ue4e7"   // hdmi-port
HEADING                            :: "\ue384"   // heading
HEADING_1                          :: "\ue385"   // heading-1
HEADING_2                          :: "\ue386"   // heading-2
HEADING_3                          :: "\ue387"   // heading-3
HEADING_4                          :: "\ue388"   // heading-4
HEADING_5                          :: "\ue389"   // heading-5
HEADING_6                          :: "\ue38a"   // heading-6
HEADPHONE_OFF                      :: "\ue629"   // headphone-off
HEADPHONES                         :: "\ue0f1"   // headphones
HEADSET                            :: "\ue5bd"   // headset
HEART                              :: "\ue0f2"   // heart
HEART_CRACK                        :: "\ue2d6"   // heart-crack
HEART_HANDSHAKE                    :: "\ue2d7"   // heart-handshake
HEART_MINUS                        :: "\ue651"   // heart-minus
HEART_OFF                          :: "\ue295"   // heart-off
HEART_PLUS                         :: "\ue652"   // heart-plus
HEART_PULSE                        :: "\ue36e"   // heart-pulse
HEART_X                            :: "\ue6ed"   // heart-x
HEATER                             :: "\ue58e"   // heater
HELICOPTER                         :: "\ue69d"   // helicopter
HEXAGON                            :: "\ue0f3"   // hexagon
HIGHLIGHTER                        :: "\ue0f4"   // highlighter
HIKING_STICK                       :: "\ue79a"   // hiking-stick
HISTORY                            :: "\ue1f5"   // history
HOME                               :: "\ue0f5"   // home
HOP                                :: "\ue397"   // hop
HOP_OFF                            :: "\ue398"   // hop-off
HOSPITAL                           :: "\ue5d8"   // hospital
HOTEL                              :: "\ue3e2"   // hotel
HOURGLASS                          :: "\ue296"   // hourglass
HOURGLASS_COG                      :: "\ue76e"   // hourglass-cog
HOUSE_COG                          :: "\ue788"   // house-cog
HOUSE_HEART                        :: "\ue695"   // house-heart
HOUSE_PLUG                         :: "\ue5f0"   // house-plug
HOUSE_PLUS                         :: "\ue5f1"   // house-plus
HOUSE_WIFI                         :: "\ue63c"   // house-wifi
HOUSES                             :: "\ue76f"   // houses
ICE_CREAM_2                        :: "\ue3a7"   // ice-cream-2
ICE_CREAM_CONE                     :: "\ue353"   // ice-cream-cone
ID_CARD                            :: "\ue617"   // id-card
ID_CARD_LANYARD                    :: "\ue670"   // id-card-lanyard
IMAGE                              :: "\ue0f6"   // image
IMAGE_DOWN                         :: "\ue53c"   // image-down
IMAGE_MINUS                        :: "\ue1f6"   // image-minus
IMAGE_OFF                          :: "\ue1c0"   // image-off
IMAGE_PLAY                         :: "\ue5df"   // image-play
IMAGE_PLUS                         :: "\ue1f7"   // image-plus
IMAGE_UP                           :: "\ue5cb"   // image-up
IMAGE_UPSCALE                      :: "\ue637"   // image-upscale
IMAGES                             :: "\ue5c4"   // images
IMPORT                             :: "\ue22f"   // import
INBOX                              :: "\ue0f7"   // inbox
INDENT_DECREASE                    :: "\ue107"   // indent-decrease
INDENT_INCREASE                    :: "\ue108"   // indent-increase
INDIAN_RUPEE                       :: "\ue0f8"   // indian-rupee
INFINITY                           :: "\ue1e7"   // infinity
INFO                               :: "\ue0f9"   // info
INSPECT                            :: "\ue202"   // inspect
INSPECTION_PANEL                   :: "\ue583"   // inspection-panel
ITALIC                             :: "\ue0fb"   // italic
ITERATION_CCW                      :: "\ue423"   // iteration-ccw
ITERATION_CW                       :: "\ue424"   // iteration-cw
IV_BAG                             :: "\ue770"   // iv-bag
JAPANESE_YEN                       :: "\ue0fc"   // japanese-yen
JOYSTICK                           :: "\ue355"   // joystick
KANBAN                             :: "\ue4dc"   // kanban
KANBAN_SQUARE                      :: "\ue170"   // kanban-square
KANBAN_SQUARE_DASHED               :: "\ue16c"   // kanban-square-dashed
KAYAK                              :: "\ue68f"   // kayak
KAZAKH_TENGE                       :: "\ue793"   // kazakh-tenge
KEY                                :: "\ue0fd"   // key
KEY_ROUND                          :: "\ue4a3"   // key-round
KEY_SQUARE                         :: "\ue4a4"   // key-square
KEYBOARD                           :: "\ue284"   // keyboard
KEYBOARD_MUSIC                     :: "\ue560"   // keyboard-music
KEYBOARD_OFF                       :: "\ue5de"   // keyboard-off
LAMBDA                             :: "\ue780"   // lambda
LAMP                               :: "\ue2d8"   // lamp
LAMP_CEILING                       :: "\ue2d9"   // lamp-ceiling
LAMP_DESK                          :: "\ue2da"   // lamp-desk
LAMP_FLOOR                         :: "\ue2db"   // lamp-floor
LAMP_WALL_DOWN                     :: "\ue2dc"   // lamp-wall-down
LAMP_WALL_UP                       :: "\ue2dd"   // lamp-wall-up
LAND_PLOT                          :: "\ue528"   // land-plot
LANDMARK                           :: "\ue23a"   // landmark
LANGUAGES                          :: "\ue0fe"   // languages
LAPTOP                             :: "\ue1cd"   // laptop
LAPTOP_2                           :: "\ue1d8"   // laptop-2
LAPTOP_MINIMAL_CHECK               :: "\ue632"   // laptop-minimal-check
LASSO                              :: "\ue1ce"   // lasso
LASSO_SELECT                       :: "\ue1cf"   // lasso-select
LAYER_ARROW_DOWN                   :: "\ue72a"   // layer-arrow-down
LAYER_ARROW_UP                     :: "\ue72b"   // layer-arrow-up
LAYERS_2                           :: "\ue52a"   // layers-2
LAYERS_3                           :: "\ue529"   // layers-3
LAYERS_ARROW_DOWN                  :: "\ue72c"   // layers-arrow-down
LAYERS_ARROW_UP                    :: "\ue72d"   // layers-arrow-up
LAYERS_MINUS                       :: "\ue6ee"   // layers-minus
LAYERS_PLUS                        :: "\ue6e6"   // layers-plus
LAYOUT                             :: "\ue12c"   // layout
LAYOUT_ARROW_DOWN                  :: "\ue771"   // layout-arrow-down
LAYOUT_ARROW_RIGHT                 :: "\ue772"   // layout-arrow-right
LAYOUT_DASHBOARD                   :: "\ue1c1"   // layout-dashboard
LAYOUT_FREEFORM                    :: "\ue723"   // layout-freeform
LAYOUT_GRID                        :: "\ue0ff"   // layout-grid
LAYOUT_GRID_CIRCLES                :: "\ue790"   // layout-grid-circles
LAYOUT_LIST                        :: "\ue1d9"   // layout-list
LAYOUT_PANEL_LEFT                  :: "\ue470"   // layout-panel-left
LAYOUT_PANEL_TOP                   :: "\ue471"   // layout-panel-top
LAYOUT_TEMPLATE                    :: "\ue207"   // layout-template
LEAF                               :: "\ue2de"   // leaf
LEAFY_GREEN                        :: "\ue46f"   // leafy-green
LECTERN                            :: "\ue5e9"   // lectern
LENS                               :: "\ue79c"   // lens
LENS_CONCAVE                       :: "\ue6b7"   // lens-concave
LENS_CONVEX                        :: "\ue6b8"   // lens-convex
LETTER_TEXT                        :: "\ue605"   // letter-text
LETTERS                            :: "\ue78e"   // letters
LIBRARY                            :: "\ue100"   // library
LIBRARY_BIG                        :: "\ue54e"   // library-big
LIBRARY_SQUARE                     :: "\ue54f"   // library-square
LIFE_BUOY                          :: "\ue101"   // life-buoy
LIGATURE                           :: "\ue43a"   // ligature
LIGHTBULB                          :: "\ue1c2"   // lightbulb
LIGHTBULB_OFF                      :: "\ue208"   // lightbulb-off
LIGHTHOUSE                         :: "\ue751"   // lighthouse
LINE_DOT_BOTTOM_VERTICAL           :: "\ue789"   // line-dot-bottom-vertical
LINE_DOT_LEFT_HORIZONTAL           :: "\ue78a"   // line-dot-left-horizontal
LINE_DOT_RIGHT_HORIZONTAL          :: "\ue6b9"   // line-dot-right-horizontal
LINE_DOT_TOP_VERTICAL              :: "\ue78b"   // line-dot-top-vertical
LINE_SQUIGGLE                      :: "\ue67a"   // line-squiggle
LINE_STYLE                         :: "\ue6da"   // line-style
LINK                               :: "\ue102"   // link
LINK_2                             :: "\ue103"   // link-2
LINK_2_OFF                         :: "\ue104"   // link-2-off
LIST                               :: "\ue106"   // list
LIST_CHECK                         :: "\ue5fa"   // list-check
LIST_CHECKS                        :: "\ue1d0"   // list-checks
LIST_CHEVRONS_DOWN_UP              :: "\ue694"   // list-chevrons-down-up
LIST_CHEVRONS_UP_DOWN              :: "\ue696"   // list-chevrons-up-down
LIST_CLOCK                         :: "\ue738"   // list-clock
LIST_COLLAPSE                      :: "\ue59b"   // list-collapse
LIST_END                           :: "\ue2df"   // list-end
LIST_FILTER                        :: "\ue460"   // list-filter
LIST_FILTER_PLUS                   :: "\ue639"   // list-filter-plus
LIST_MINUS                         :: "\ue23e"   // list-minus
LIST_MUSIC                         :: "\ue2e0"   // list-music
LIST_ORDERED                       :: "\ue1d1"   // list-ordered
LIST_PLUS                          :: "\ue23f"   // list-plus
LIST_RESTART                       :: "\ue452"   // list-restart
LIST_SORT_ASCENDING                :: "\ue702"   // list-sort-ascending
LIST_SORT_DESCENDING               :: "\ue703"   // list-sort-descending
LIST_START                         :: "\ue2e1"   // list-start
LIST_TODO                          :: "\ue4c3"   // list-todo
LIST_TREE                          :: "\ue408"   // list-tree
LIST_VIDEO                         :: "\ue2e2"   // list-video
LIST_X                             :: "\ue240"   // list-x
LOADER                             :: "\ue109"   // loader
LOADER_2                           :: "\ue10a"   // loader-2
LOADER_PINWHEEL                    :: "\ue5e6"   // loader-pinwheel
LOCATE                             :: "\ue1da"   // locate
LOCATE_FIXED                       :: "\ue1db"   // locate-fixed
LOCATE_OFF                         :: "\ue282"   // locate-off
LOCATION_EDIT                      :: "\ue655"   // location-edit
LOCK                               :: "\ue10b"   // lock
LOCK_KEYHOLE                       :: "\ue531"   // lock-keyhole
LOCK_KEYHOLE_OPEN                  :: "\ue532"   // lock-keyhole-open
LOCK_OPEN                          :: "\ue10c"   // lock-open
LOG_IN                             :: "\ue10d"   // log-in
LOG_OUT                            :: "\ue10e"   // log-out
LOGS                               :: "\ue5f4"   // logs
LOLLIPOP                           :: "\ue4bd"   // lollipop
LUGGAGE                            :: "\ue2ca"   // luggage
M_SQUARE                           :: "\ue503"   // m-square
MAGNET                             :: "\ue2b5"   // magnet
MAIL                               :: "\ue10f"   // mail
MAIL_BADGE                         :: "\ue734"   // mail-badge
MAIL_CHECK                         :: "\ue361"   // mail-check
MAIL_CLOCK                         :: "\ue73e"   // mail-clock
MAIL_DOT                           :: "\ue79e"   // mail-dot
MAIL_MINUS                         :: "\ue362"   // mail-minus
MAIL_OPEN                          :: "\ue363"   // mail-open
MAIL_PEN                           :: "\ue74e"   // mail-pen
MAIL_PLUS                          :: "\ue364"   // mail-plus
MAIL_QUESTION_MARK                 :: "\ue365"   // mail-question-mark
MAIL_SEARCH                        :: "\ue366"   // mail-search
MAIL_WARNING                       :: "\ue367"   // mail-warning
MAIL_X                             :: "\ue368"   // mail-x
MAILBOX                            :: "\ue3d4"   // mailbox
MAILS                              :: "\ue369"   // mails
MAP                                :: "\ue110"   // map
MAP_MINUS                          :: "\ue686"   // map-minus
MAP_PIN                            :: "\ue111"   // map-pin
MAP_PIN_CHECK                      :: "\ue60f"   // map-pin-check
MAP_PIN_CHECK_INSIDE               :: "\ue610"   // map-pin-check-inside
MAP_PIN_HOUSE                      :: "\ue61c"   // map-pin-house
MAP_PIN_MINUS                      :: "\ue611"   // map-pin-minus
MAP_PIN_MINUS_INSIDE               :: "\ue612"   // map-pin-minus-inside
MAP_PIN_OFF                        :: "\ue2a6"   // map-pin-off
MAP_PIN_PLUS                       :: "\ue613"   // map-pin-plus
MAP_PIN_PLUS_INSIDE                :: "\ue614"   // map-pin-plus-inside
MAP_PIN_SEARCH                     :: "\ue6de"   // map-pin-search
MAP_PIN_X                          :: "\ue615"   // map-pin-x
MAP_PIN_X_INSIDE                   :: "\ue616"   // map-pin-x-inside
MAP_PINNED                         :: "\ue53d"   // map-pinned
MAP_PLUS                           :: "\ue63f"   // map-plus
MARS                               :: "\ue641"   // mars
MARS_STROKE                        :: "\ue642"   // mars-stroke
MARTINI                            :: "\ue2e3"   // martini
MAXIMIZE                           :: "\ue112"   // maximize
MAXIMIZE_2                         :: "\ue113"   // maximize-2
MEDAL                              :: "\ue36f"   // medal
MEGAPHONE                          :: "\ue235"   // megaphone
MEGAPHONE_OFF                      :: "\ue370"   // megaphone-off
MEMORY_STICK                       :: "\ue445"   // memory-stick
MENU                               :: "\ue115"   // menu
MENU_SQUARE                        :: "\ue453"   // menu-square
MERGE                              :: "\ue43f"   // merge
MESSAGE_CIRCLE                     :: "\ue116"   // message-circle
MESSAGE_CIRCLE_CHECK               :: "\ue6ba"   // message-circle-check
MESSAGE_CIRCLE_CODE                :: "\ue562"   // message-circle-code
MESSAGE_CIRCLE_DASHED              :: "\ue563"   // message-circle-dashed
MESSAGE_CIRCLE_DASHED_CHECK        :: "\ue746"   // message-circle-dashed-check
MESSAGE_CIRCLE_HEART               :: "\ue564"   // message-circle-heart
MESSAGE_CIRCLE_MORE                :: "\ue565"   // message-circle-more
MESSAGE_CIRCLE_OFF                 :: "\ue566"   // message-circle-off
MESSAGE_CIRCLE_PLUS                :: "\ue567"   // message-circle-plus
MESSAGE_CIRCLE_QUESTION_MARK       :: "\ue568"   // message-circle-question-mark
MESSAGE_CIRCLE_REPLY               :: "\ue569"   // message-circle-reply
MESSAGE_CIRCLE_WARNING             :: "\ue56a"   // message-circle-warning
MESSAGE_CIRCLE_X                   :: "\ue56b"   // message-circle-x
MESSAGE_SQUARE                     :: "\ue117"   // message-square
MESSAGE_SQUARE_CHECK               :: "\ue6bb"   // message-square-check
MESSAGE_SQUARE_CODE                :: "\ue56c"   // message-square-code
MESSAGE_SQUARE_DASHED              :: "\ue40b"   // message-square-dashed
MESSAGE_SQUARE_DIFF                :: "\ue56d"   // message-square-diff
MESSAGE_SQUARE_DOT                 :: "\ue56e"   // message-square-dot
MESSAGE_SQUARE_HEART               :: "\ue56f"   // message-square-heart
MESSAGE_SQUARE_LOCK                :: "\ue62c"   // message-square-lock
MESSAGE_SQUARE_MORE                :: "\ue570"   // message-square-more
MESSAGE_SQUARE_OFF                 :: "\ue571"   // message-square-off
MESSAGE_SQUARE_PLUS                :: "\ue40c"   // message-square-plus
MESSAGE_SQUARE_QUOTE               :: "\ue572"   // message-square-quote
MESSAGE_SQUARE_REPLY               :: "\ue573"   // message-square-reply
MESSAGE_SQUARE_SHARE               :: "\ue574"   // message-square-share
MESSAGE_SQUARE_TEXT                :: "\ue575"   // message-square-text
MESSAGE_SQUARE_WARNING             :: "\ue576"   // message-square-warning
MESSAGE_SQUARE_X                   :: "\ue577"   // message-square-x
MESSAGES_CIRCLE                    :: "\ue773"   // messages-circle
MESSAGES_SQUARE                    :: "\ue40d"   // messages-square
METRONOME                          :: "\ue6bc"   // metronome
MIC                                :: "\ue118"   // mic
MIC_2                              :: "\ue349"   // mic-2
MIC_AUDIO_LINES                    :: "\ue724"   // mic-audio-lines
MIC_OFF                            :: "\ue119"   // mic-off
MIC_SIGNAL                         :: "\ue1fa"   // mic-signal
MICROCHIP                          :: "\ue61a"   // microchip
MICROSCOPE                         :: "\ue2e4"   // microscope
MICROWAVE                          :: "\ue37a"   // microwave
MIDI_PORT                          :: "\ue739"   // midi-port
MILESTONE                          :: "\ue298"   // milestone
MILK                               :: "\ue399"   // milk
MILK_OFF                           :: "\ue39a"   // milk-off
MINIMIZE                           :: "\ue11a"   // minimize
MINIMIZE_2                         :: "\ue11b"   // minimize-2
MINUS                              :: "\ue11c"   // minus
MINUS_SQUARE                       :: "\ue171"   // minus-square
MIRROR_RECTANGULAR                 :: "\ue6bd"   // mirror-rectangular
MIRROR_ROUND                       :: "\ue6be"   // mirror-round
MONITOR                            :: "\ue11d"   // monitor
MONITOR_CHECK                      :: "\ue482"   // monitor-check
MONITOR_CLOUD                      :: "\ue699"   // monitor-cloud
MONITOR_COG                        :: "\ue603"   // monitor-cog
MONITOR_DOT                        :: "\ue483"   // monitor-dot
MONITOR_DOWN                       :: "\ue421"   // monitor-down
MONITOR_OFF                        :: "\ue1dc"   // monitor-off
MONITOR_PAUSE                      :: "\ue484"   // monitor-pause
MONITOR_PC                         :: "\ue77c"   // monitor-pc
MONITOR_PLAY                       :: "\ue485"   // monitor-play
MONITOR_SMARTPHONE                 :: "\ue3a2"   // monitor-smartphone
MONITOR_SPEAKER                    :: "\ue210"   // monitor-speaker
MONITOR_STOP                       :: "\ue486"   // monitor-stop
MONITOR_UP                         :: "\ue422"   // monitor-up
MONITOR_X                          :: "\ue487"   // monitor-x
MOON                               :: "\ue11e"   // moon
MOON_STAR                          :: "\ue410"   // moon-star
MOP                                :: "\ue73b"   // mop
MOP_SPARKLES                       :: "\ue73a"   // mop-sparkles
MOSQUE                             :: "\ue725"   // mosque
MOTORBIKE                          :: "\ue698"   // motorbike
MOUNTAIN                           :: "\ue231"   // mountain
MOUNTAIN_SNOW                      :: "\ue232"   // mountain-snow
MOUSE                              :: "\ue28e"   // mouse
MOUSE_LEFT                         :: "\ue6bf"   // mouse-left
MOUSE_OFF                          :: "\ue5db"   // mouse-off
MOUSE_POINTER                      :: "\ue11f"   // mouse-pointer
MOUSE_POINTER_2                    :: "\ue1c3"   // mouse-pointer-2
MOUSE_POINTER_2_OFF                :: "\ue6a6"   // mouse-pointer-2-off
MOUSE_POINTER_BAN                  :: "\ue5e7"   // mouse-pointer-ban
MOUSE_POINTER_CLICK                :: "\ue120"   // mouse-pointer-click
MOUSE_POINTER_SQUARE_DASHED        :: "\ue509"   // mouse-pointer-square-dashed
MOUSE_RIGHT                        :: "\ue6c0"   // mouse-right
MOUTH                              :: "\ue775"   // mouth
MOUTH_OFF                          :: "\ue774"   // mouth-off
MOVE                               :: "\ue121"   // move
MOVE_3_D                           :: "\ue2e5"   // move-3-d
MOVE_DIAGONAL                      :: "\ue1c4"   // move-diagonal
MOVE_DIAGONAL_2                    :: "\ue1c5"   // move-diagonal-2
MOVE_DOWN                          :: "\ue48c"   // move-down
MOVE_DOWN_LEFT                     :: "\ue48d"   // move-down-left
MOVE_DOWN_RIGHT                    :: "\ue48e"   // move-down-right
MOVE_HORIZONTAL                    :: "\ue1c6"   // move-horizontal
MOVE_LEFT                          :: "\ue48f"   // move-left
MOVE_RIGHT                         :: "\ue490"   // move-right
MOVE_UP                            :: "\ue491"   // move-up
MOVE_UP_LEFT                       :: "\ue492"   // move-up-left
MOVE_UP_RIGHT                      :: "\ue493"   // move-up-right
MOVE_VERTICAL                      :: "\ue1c7"   // move-vertical
MUSIC                              :: "\ue122"   // music
MUSIC_2                            :: "\ue34a"   // music-2
MUSIC_3                            :: "\ue34b"   // music-3
MUSIC_4                            :: "\ue34c"   // music-4
NAVIGATION                         :: "\ue123"   // navigation
NAVIGATION_2                       :: "\ue124"   // navigation-2
NAVIGATION_2_OFF                   :: "\ue2a7"   // navigation-2-off
NAVIGATION_OFF                     :: "\ue2a8"   // navigation-off
NEPALI_RUPEE                       :: "\ue781"   // nepali-rupee
NETWORK                            :: "\ue125"   // network
NEWSPAPER                          :: "\ue348"   // newspaper
NFC                                :: "\ue3c3"   // nfc
NON_BINARY                         :: "\ue643"   // non-binary
NOTEBOOK                           :: "\ue595"   // notebook
NOTEBOOK_DOT                       :: "\ue776"   // notebook-dot
NOTEBOOK_PEN                       :: "\ue596"   // notebook-pen
NOTEBOOK_TABS                      :: "\ue597"   // notebook-tabs
NOTEBOOK_TEXT                      :: "\ue598"   // notebook-text
NOTEPAD_TEXT                       :: "\ue599"   // notepad-text
NOTEPAD_TEXT_DASHED                :: "\ue59a"   // notepad-text-dashed
NUT                                :: "\ue39b"   // nut
NUT_OFF                            :: "\ue39c"   // nut-off
OCTAGON                            :: "\ue126"   // octagon
OCTAGON_MINUS                      :: "\ue627"   // octagon-minus
OCTAGON_PAUSE                      :: "\ue21b"   // octagon-pause
OCTAGON_X                          :: "\ue128"   // octagon-x
OMEGA                              :: "\ue619"   // omega
OPTION                             :: "\ue1f8"   // option
ORBIT                              :: "\ue3e7"   // orbit
ORIGAMI                            :: "\ue5e3"   // origami
PACKAGE                            :: "\ue129"   // package
PACKAGE_2                          :: "\ue340"   // package-2
PACKAGE_CHECK                      :: "\ue266"   // package-check
PACKAGE_MINUS                      :: "\ue267"   // package-minus
PACKAGE_OPEN                       :: "\ue2cc"   // package-open
PACKAGE_PLUS                       :: "\ue268"   // package-plus
PACKAGE_SEARCH                     :: "\ue269"   // package-search
PACKAGE_X                          :: "\ue26a"   // package-x
PAINT_BUCKET                       :: "\ue2e6"   // paint-bucket
PAINT_ROLLER                       :: "\ue59e"   // paint-roller
PAINTBRUSH                         :: "\ue2e7"   // paintbrush
PAINTBRUSH_2                       :: "\ue2e8"   // paintbrush-2
PALETTE                            :: "\ue1dd"   // palette
PALMTREE                           :: "\ue281"   // palmtree
PANDA                              :: "\ue668"   // panda
PANEL_BOTTOM                       :: "\ue42c"   // panel-bottom
PANEL_BOTTOM_CLOSE                 :: "\ue42d"   // panel-bottom-close
PANEL_BOTTOM_DASHED                :: "\ue42e"   // panel-bottom-dashed
PANEL_BOTTOM_OPEN                  :: "\ue42f"   // panel-bottom-open
PANEL_LEFT                         :: "\ue12a"   // panel-left
PANEL_LEFT_CLOSE                   :: "\ue21c"   // panel-left-close
PANEL_LEFT_DASHED                  :: "\ue430"   // panel-left-dashed
PANEL_LEFT_OPEN                    :: "\ue21d"   // panel-left-open
PANEL_LEFT_RIGHT_DASHED            :: "\ue692"   // panel-left-right-dashed
PANEL_RIGHT                        :: "\ue431"   // panel-right
PANEL_RIGHT_CLOSE                  :: "\ue432"   // panel-right-close
PANEL_RIGHT_DASHED                 :: "\ue433"   // panel-right-dashed
PANEL_RIGHT_OPEN                   :: "\ue434"   // panel-right-open
PANEL_TOP                          :: "\ue435"   // panel-top
PANEL_TOP_BOTTOM_DASHED            :: "\ue693"   // panel-top-bottom-dashed
PANEL_TOP_CLOSE                    :: "\ue436"   // panel-top-close
PANEL_TOP_DASHED                   :: "\ue437"   // panel-top-dashed
PANEL_TOP_OPEN                     :: "\ue438"   // panel-top-open
PANELS_LEFT_BOTTOM                 :: "\ue12b"   // panels-left-bottom
PANELS_RIGHT_BOTTOM                :: "\ue588"   // panels-right-bottom
PANELS_TOP_BOTTOM                  :: "\ue58a"   // panels-top-bottom
PAPER_BAG                          :: "\ue71d"   // paper-bag
PAPERCLIP                          :: "\ue12d"   // paperclip
PARASOL                            :: "\ue6fd"   // parasol
PARENTHESES                        :: "\ue444"   // parentheses
PARK                               :: "\ue777"   // park
PARKING_METER                      :: "\ue500"   // parking-meter
PARKING_SQUARE                     :: "\ue3cb"   // parking-square
PARKING_SQUARE_OFF                 :: "\ue3cc"   // parking-square-off
PARTY_POPPER                       :: "\ue343"   // party-popper
PAUSE                              :: "\ue12e"   // pause
PAW_PRINT                          :: "\ue4f5"   // paw-print
PC_CASE                            :: "\ue446"   // pc-case
PEN_OFF                            :: "\ue5ee"   // pen-off
PEN_TOOL                           :: "\ue131"   // pen-tool
PENCIL                             :: "\ue1f9"   // pencil
PENCIL_LINE                        :: "\ue4f0"   // pencil-line
PENCIL_OFF                         :: "\ue5ef"   // pencil-off
PENCIL_RULER                       :: "\ue4f1"   // pencil-ruler
PENCIL_SPARKLES                    :: "\ue70f"   // pencil-sparkles
PENTAGON                           :: "\ue52b"   // pentagon
PERCENT                            :: "\ue132"   // percent
PERCENT_SQUARE                     :: "\ue51c"   // percent-square
PERSON_STANDING                    :: "\ue21e"   // person-standing
PHI                                :: "\ue71c"   // phi
PHILIPPINE_PESO                    :: "\ue604"   // philippine-peso
PHONE                              :: "\ue133"   // phone
PHONE_CALL                         :: "\ue134"   // phone-call
PHONE_FORWARDED                    :: "\ue135"   // phone-forwarded
PHONE_INCOMING                     :: "\ue136"   // phone-incoming
PHONE_LOG                          :: "\ue79f"   // phone-log
PHONE_MISSED                       :: "\ue137"   // phone-missed
PHONE_OFF                          :: "\ue138"   // phone-off
PHONE_OUTGOING                     :: "\ue139"   // phone-outgoing
PI                                 :: "\ue472"   // pi
PI_SQUARE                          :: "\ue488"   // pi-square
PIANO                              :: "\ue561"   // piano
PICKAXE                            :: "\ue5c6"   // pickaxe
PICTURE_IN_PICTURE                 :: "\ue3ae"   // picture-in-picture
PICTURE_IN_PICTURE_2               :: "\ue3af"   // picture-in-picture-2
PIGGY_BANK                         :: "\ue13a"   // piggy-bank
PILCROW                            :: "\ue3a3"   // pilcrow
PILCROW_LEFT                       :: "\ue5dc"   // pilcrow-left
PILCROW_RIGHT                      :: "\ue5dd"   // pilcrow-right
PILCROW_SQUARE                     :: "\ue48b"   // pilcrow-square
PILL                               :: "\ue3bd"   // pill
PILL_BOTTLE                        :: "\ue5ea"   // pill-bottle
PIN                                :: "\ue259"   // pin
PIN_OFF                            :: "\ue2b6"   // pin-off
PIPETTE                            :: "\ue13b"   // pipette
PIZZA                              :: "\ue354"   // pizza
PLANE                              :: "\ue1de"   // plane
PLANE_LANDING                      :: "\ue3cd"   // plane-landing
PLANE_TAKEOFF                      :: "\ue3ce"   // plane-takeoff
PLANT_POT                          :: "\ue778"   // plant-pot
PLAY                               :: "\ue13c"   // play
PLAY_OFF                           :: "\ue6fe"   // play-off
PLAY_SQUARE                        :: "\ue481"   // play-square
PLAYING_CARD                       :: "\ue747"   // playing-card
PLAYING_CARDS                      :: "\ue749"   // playing-cards
PLAYING_CARDS_FAN                  :: "\ue748"   // playing-cards-fan
PLUG                               :: "\ue37f"   // plug
PLUG_2                             :: "\ue380"   // plug-2
PLUG_ZAP_2                         :: "\ue45c"   // plug-zap-2
PLUS                               :: "\ue13d"   // plus
PLUS_SQUARE                        :: "\ue173"   // plus-square
POCKET_KNIFE                       :: "\ue4a0"   // pocket-knife
PODIUM                             :: "\ue704"   // podium
POINTER                            :: "\ue1e8"   // pointer
POINTER_OFF                        :: "\ue57f"   // pointer-off
POPCORN                            :: "\ue4be"   // popcorn
POPSICLE                           :: "\ue4bf"   // popsicle
POUND_STERLING                     :: "\ue13f"   // pound-sterling
POWER                              :: "\ue140"   // power
POWER_OFF                          :: "\ue209"   // power-off
POWER_SQUARE                       :: "\ue551"   // power-square
PRESENTATION                       :: "\ue4ae"   // presentation
PRINTER                            :: "\ue141"   // printer
PRINTER_3D                         :: "\ue78f"   // printer-3d
PRINTER_CHECK                      :: "\ue5f5"   // printer-check
PRINTER_X                          :: "\ue6c1"   // printer-x
PROJECTOR                          :: "\ue4af"   // projector
PROPORTIONS                        :: "\ue5cf"   // proportions
PUZZLE                             :: "\ue29c"   // puzzle
PYRAMID                            :: "\ue52c"   // pyramid
QR_CODE                            :: "\ue1df"   // qr-code
QUOTE                              :: "\ue239"   // quote
RABBIT                             :: "\ue4f6"   // rabbit
RADAR                              :: "\ue497"   // radar
RADIATION                          :: "\ue442"   // radiation
RADICAL                            :: "\ue5c2"   // radical
RADIO                              :: "\ue142"   // radio
RADIO_OFF                          :: "\ue6dd"   // radio-off
RADIO_RECEIVER                     :: "\ue1fb"   // radio-receiver
RADIO_TOWER                        :: "\ue404"   // radio-tower
RADIUS                             :: "\ue52d"   // radius
RAINBOW                            :: "\ue4c2"   // rainbow
RAT                                :: "\ue3eb"   // rat
RATIO                              :: "\ue4e8"   // ratio
RECEIPT                            :: "\ue3d3"   // receipt
RECEIPT_CENT                       :: "\ue5a5"   // receipt-cent
RECEIPT_EURO                       :: "\ue5a6"   // receipt-euro
RECEIPT_INDIAN_RUPEE               :: "\ue5a7"   // receipt-indian-rupee
RECEIPT_JAPANESE_YEN               :: "\ue5a8"   // receipt-japanese-yen
RECEIPT_POUND_STERLING             :: "\ue5a9"   // receipt-pound-sterling
RECEIPT_RUSSIAN_RUBLE              :: "\ue5aa"   // receipt-russian-ruble
RECEIPT_SWISS_FRANC                :: "\ue5ab"   // receipt-swiss-franc
RECEIPT_TEXT                       :: "\ue5ac"   // receipt-text
RECEIPT_TURKISH_LIRA               :: "\ue67f"   // receipt-turkish-lira
RECTANGLE_CIRCLE                   :: "\ue673"   // rectangle-circle
RECTANGLE_GOGGLES                  :: "\ue656"   // rectangle-goggles
RECTANGLE_HORIZONTAL               :: "\ue376"   // rectangle-horizontal
RECTANGLE_VERTICAL                 :: "\ue377"   // rectangle-vertical
RECYCLE                            :: "\ue2e9"   // recycle
REDO                               :: "\ue143"   // redo
REDO_2                             :: "\ue2a0"   // redo-2
REDO_DOT                           :: "\ue450"   // redo-dot
REFRESH_CCW                        :: "\ue144"   // refresh-ccw
REFRESH_CCW_DOT                    :: "\ue4b2"   // refresh-ccw-dot
REFRESH_CW                         :: "\ue145"   // refresh-cw
REFRESH_CW_OFF                     :: "\ue498"   // refresh-cw-off
REFRIGERATOR                       :: "\ue37b"   // refrigerator
REGEX                              :: "\ue1fc"   // regex
REMOVE_FORMATTING                  :: "\ue3b3"   // remove-formatting
REPEAT                             :: "\ue146"   // repeat
REPEAT_1                           :: "\ue1fd"   // repeat-1
REPEAT_2                           :: "\ue411"   // repeat-2
REPEAT_OFF                         :: "\ue6f3"   // repeat-off
REPLACE                            :: "\ue3db"   // replace
REPLACE_ALL                        :: "\ue3dc"   // replace-all
REPLY                              :: "\ue22a"   // reply
REPLY_ALL                          :: "\ue22b"   // reply-all
REWIND                             :: "\ue147"   // rewind
RIBBON                             :: "\ue558"   // ribbon
ROAD                               :: "\ue6d9"   // road
ROBOT_ARM                          :: "\ue740"   // robot-arm
ROBOT_VACUUM                       :: "\ue74a"   // robot-vacuum
ROCKET                             :: "\ue286"   // rocket
ROCKING_CHAIR                      :: "\ue233"   // rocking-chair
ROLLER_COASTER                     :: "\ue480"   // roller-coaster
ROSE                               :: "\ue691"   // rose
ROTATE_3_D                         :: "\ue2ea"   // rotate-3-d
ROTATE_CCW                         :: "\ue148"   // rotate-ccw
ROTATE_CCW_KEY                     :: "\ue650"   // rotate-ccw-key
ROTATE_CCW_SQUARE                  :: "\ue5d0"   // rotate-ccw-square
ROTATE_CW                          :: "\ue149"   // rotate-cw
ROTATE_CW_CLOCK                    :: "\ue782"   // rotate-cw-clock
ROTATE_CW_FADING_CLOCK             :: "\ue726"   // rotate-cw-fading-clock
ROTATE_CW_SQUARE                   :: "\ue5d1"   // rotate-cw-square
ROUTE                              :: "\ue53e"   // route
ROUTE_OFF                          :: "\ue53f"   // route-off
ROUTER                             :: "\ue3bf"   // router
ROWS_2                             :: "\ue439"   // rows-2
ROWS_4                             :: "\ue58b"   // rows-4
RSS                                :: "\ue14a"   // rss
RUGBY_BALL                         :: "\ue794"   // rugby-ball
RULER                              :: "\ue14b"   // ruler
RULER_DIMENSION_LINE               :: "\ue662"   // ruler-dimension-line
RUSSIAN_RUBLE                      :: "\ue14c"   // russian-ruble
SAILBOAT                           :: "\ue37e"   // sailboat
SALAD                              :: "\ue3a8"   // salad
SANDWICH                           :: "\ue3a9"   // sandwich
SATELLITE                          :: "\ue447"   // satellite
SATELLITE_DISH                     :: "\ue448"   // satellite-dish
SAUDI_RIYAL                        :: "\ue64b"   // saudi-riyal
SAVE                               :: "\ue14d"   // save
SAVE_ALL                           :: "\ue40f"   // save-all
SAVE_CHECK                         :: "\ue710"   // save-check
SAVE_OFF                           :: "\ue5f3"   // save-off
SAVE_PEN                           :: "\ue705"   // save-pen
SAVE_PLUS                          :: "\ue706"   // save-plus
SCALE                              :: "\ue212"   // scale
SCALE_3_D                          :: "\ue2eb"   // scale-3-d
SCALING                            :: "\ue2ec"   // scaling
SCAN                               :: "\ue257"   // scan
SCAN_BARCODE                       :: "\ue535"   // scan-barcode
SCAN_BOX                           :: "\ue720"   // scan-box
SCAN_EYE                           :: "\ue536"   // scan-eye
SCAN_FACE                          :: "\ue371"   // scan-face
SCAN_HEART                         :: "\ue63a"   // scan-heart
SCAN_LINE                          :: "\ue258"   // scan-line
SCAN_QR_CODE                       :: "\ue5f6"   // scan-qr-code
SCAN_SEARCH                        :: "\ue537"   // scan-search
SCAN_SQUARE                        :: "\ue727"   // scan-square
SCAN_TEXT                          :: "\ue538"   // scan-text
SCHOOL                             :: "\ue3e3"   // school
SCHOOL_2                           :: "\ue3e5"   // school-2
SCISSORS                           :: "\ue14e"   // scissors
SCISSORS_LINE_DASHED               :: "\ue4e9"   // scissors-line-dashed
SCISSORS_SQUARE                    :: "\ue4ec"   // scissors-square
SCISSORS_SQUARE_DASHED_BOTTOM      :: "\ue4eb"   // scissors-square-dashed-bottom
SCOOTER                            :: "\ue6ac"   // scooter
SCRATCH_BLOCKS                     :: "\ue79b"   // scratch-blocks
SCREEN_SHARE                       :: "\ue14f"   // screen-share
SCREEN_SHARE_OFF                   :: "\ue150"   // screen-share-off
SCREW                              :: "\ue7a0"   // screw
SCROLL                             :: "\ue2ed"   // scroll
SCROLL_TEXT                        :: "\ue45f"   // scroll-text
SEARCH                             :: "\ue151"   // search
SEARCH_ALERT                       :: "\ue6e7"   // search-alert
SEARCH_CHECK                       :: "\ue4aa"   // search-check
SEARCH_CODE                        :: "\ue4ab"   // search-code
SEARCH_SLASH                       :: "\ue4ac"   // search-slash
SEARCH_X                           :: "\ue4ad"   // search-x
SECTION                            :: "\ue5e8"   // section
SEND                               :: "\ue152"   // send
SEND_HORIZONAL                     :: "\ue4f2"   // send-horizonal
SEND_TO_BACK                       :: "\ue4f3"   // send-to-back
SEPARATOR_HORIZONTAL               :: "\ue1c8"   // separator-horizontal
SEPARATOR_VERTICAL                 :: "\ue1c9"   // separator-vertical
SERVER                             :: "\ue153"   // server
SERVER_COG                         :: "\ue341"   // server-cog
SERVER_CRASH                       :: "\ue1e9"   // server-crash
SERVER_OFF                         :: "\ue1ea"   // server-off
SERVER_PLUS                        :: "\ue721"   // server-plus
SETTINGS                           :: "\ue154"   // settings
SETTINGS_2                         :: "\ue245"   // settings-2
SHAPES                             :: "\ue4b3"   // shapes
SHARE                              :: "\ue155"   // share
SHARE_2                            :: "\ue156"   // share-2
SHEET                              :: "\ue157"   // sheet
SHELL                              :: "\ue4f7"   // shell
SHELVING_UNIT                      :: "\ue6c2"   // shelving-unit
SHIELD                             :: "\ue158"   // shield
SHIELD_ALERT                       :: "\ue1fe"   // shield-alert
SHIELD_BAN                         :: "\ue159"   // shield-ban
SHIELD_CHECK                       :: "\ue1ff"   // shield-check
SHIELD_CLOSE                       :: "\ue200"   // shield-close
SHIELD_COG                         :: "\ue6e9"   // shield-cog
SHIELD_COG_CORNER                  :: "\ue6e8"   // shield-cog-corner
SHIELD_ELLIPSIS                    :: "\ue516"   // shield-ellipsis
SHIELD_HALF                        :: "\ue517"   // shield-half
SHIELD_HOUSE                       :: "\ue7a1"   // shield-house
SHIELD_KEYHOLE                     :: "\ue722"   // shield-keyhole
SHIELD_LOCK                        :: "\ue731"   // shield-lock
SHIELD_MINUS                       :: "\ue518"   // shield-minus
SHIELD_OFF                         :: "\ue15a"   // shield-off
SHIELD_PLUS                        :: "\ue519"   // shield-plus
SHIELD_QUESTION_MARK               :: "\ue40e"   // shield-question-mark
SHIELD_USER                        :: "\ue647"   // shield-user
SHIP                               :: "\ue3ba"   // ship
SHIP_CARGO                         :: "\ue741"   // ship-cargo
SHIP_WHEEL                         :: "\ue502"   // ship-wheel
SHIRT                              :: "\ue1ca"   // shirt
SHOPPING_BAG                       :: "\ue15b"   // shopping-bag
SHOPPING_BASKET                    :: "\ue4ea"   // shopping-basket
SHOPPING_CART                      :: "\ue15c"   // shopping-cart
SHOPPING_CART_MINUS                :: "\ue752"   // shopping-cart-minus
SHOPPING_CART_PLUS                 :: "\ue753"   // shopping-cart-plus
SHOVEL                             :: "\ue15d"   // shovel
SHOWER_HEAD                        :: "\ue37c"   // shower-head
SHREDDER                           :: "\ue65b"   // shredder
SHRIMP                             :: "\ue649"   // shrimp
SHRIMP_OFF                         :: "\ue754"   // shrimp-off
SHRINK                             :: "\ue220"   // shrink
SHRUB                              :: "\ue2ee"   // shrub
SHUFFLE                            :: "\ue15e"   // shuffle
SIGMA                              :: "\ue201"   // sigma
SIGMA_SQUARE                       :: "\ue489"   // sigma-square
SIGNAL                             :: "\ue25f"   // signal
SIGNAL_HIGH                        :: "\ue260"   // signal-high
SIGNAL_LOW                         :: "\ue261"   // signal-low
SIGNAL_MEDIUM                      :: "\ue262"   // signal-medium
SIGNAL_ZERO                        :: "\ue263"   // signal-zero
SIGNATURE                          :: "\ue5f2"   // signature
SIGNPOST                           :: "\ue540"   // signpost
SIGNPOST_BIG                       :: "\ue541"   // signpost-big
SIREN                              :: "\ue2ef"   // siren
SKIP_BACK                          :: "\ue15f"   // skip-back
SKIP_FORWARD                       :: "\ue160"   // skip-forward
SKULL                              :: "\ue221"   // skull
SLASH                              :: "\ue51d"   // slash
SLASH_SQUARE                       :: "\ue174"   // slash-square
SLICE                              :: "\ue2f0"   // slice
SLIDERS_HORIZONTAL                 :: "\ue29a"   // sliders-horizontal
SLIDERS_VERTICAL                   :: "\ue162"   // sliders-vertical
SMARTPHONE                         :: "\ue163"   // smartphone
SMARTPHONE_CHARGING                :: "\ue22e"   // smartphone-charging
SMARTPHONE_NFC                     :: "\ue3c4"   // smartphone-nfc
SNAIL                              :: "\ue4f8"   // snail
SNOWFLAKE                          :: "\ue165"   // snowflake
SOAP_DISPENSER_DROPLET             :: "\ue669"   // soap-dispenser-droplet
SOFA                               :: "\ue2c4"   // sofa
SOLAR_PANEL                        :: "\ue69f"   // solar-panel
SOUP                               :: "\ue3aa"   // soup
SPACE                              :: "\ue3dd"   // space
SPADE                              :: "\ue499"   // spade
SPARKLE                            :: "\ue47e"   // sparkle
SPARKLES                           :: "\ue412"   // sparkles
SPEAKER                            :: "\ue166"   // speaker
SPEECH                             :: "\ue51e"   // speech
SPELL_CHECK                        :: "\ue49a"   // spell-check
SPELL_CHECK_2                      :: "\ue49b"   // spell-check-2
SPLINE                             :: "\ue38b"   // spline
SPLINE_POINTER                     :: "\ue64f"   // spline-pointer
SPLIT                              :: "\ue440"   // split
SPLIT_SQUARE_HORIZONTAL            :: "\ue3b6"   // split-square-horizontal
SPLIT_SQUARE_VERTICAL              :: "\ue3b7"   // split-square-vertical
SPOOL                              :: "\ue677"   // spool
SPORT_SHOE                         :: "\ue6db"   // sport-shoe
SPOTLIGHT                          :: "\ue682"   // spotlight
SPRAY_CAN                          :: "\ue495"   // spray-can
SPROUT                             :: "\ue1eb"   // sprout
SQUARE                             :: "\ue167"   // square
SQUARE_ARROW_RIGHT_ENTER           :: "\ue6c3"   // square-arrow-right-enter
SQUARE_ARROW_RIGHT_EXIT            :: "\ue6c4"   // square-arrow-right-exit
SQUARE_DASHED_BOTTOM               :: "\ue4c0"   // square-dashed-bottom
SQUARE_DASHED_BOTTOM_CODE          :: "\ue4c1"   // square-dashed-bottom-code
SQUARE_DASHED_PLUS                 :: "\ue783"   // square-dashed-plus
SQUARE_DASHED_TEXT                 :: "\ue3de"   // square-dashed-text
SQUARE_DASHED_TOP_SOLID            :: "\ue66c"   // square-dashed-top-solid
SQUARE_DASHED_X                    :: "\ue785"   // square-dashed-x
SQUARE_DASHED_X_CORNER             :: "\ue784"   // square-dashed-x-corner
SQUARE_DIMENSIONS                  :: "\ue73c"   // square-dimensions
SQUARE_EXCLAMATION_POINT           :: "\ue75b"   // square-exclamation-point
SQUARE_OFF                         :: "\ue728"   // square-off
SQUARE_PAUSE                       :: "\ue684"   // square-pause
SQUARE_RADICAL                     :: "\ue5c3"   // square-radical
SQUARE_ROUND_CORNER                :: "\ue648"   // square-round-corner
SQUARE_SPARKLES                    :: "\ue78c"   // square-sparkles
SQUARE_SQUARE                      :: "\ue60e"   // square-square
SQUARE_STACK                       :: "\ue4a2"   // square-stack
SQUARE_STAR                        :: "\ue68e"   // square-star
SQUARE_STOP                        :: "\ue685"   // square-stop
SQUARE_TERMINAL                    :: "\ue20a"   // square-terminal
SQUARE_TEXT                        :: "\ue736"   // square-text
SQUARE_USER                        :: "\ue465"   // square-user
SQUARE_USER_ROUND                  :: "\ue466"   // square-user-round
SQUARE_X                           :: "\ue175"   // square-x
SQUARES_EXCLUDE                    :: "\ue657"   // squares-exclude
SQUARES_INTERSECT                  :: "\ue658"   // squares-intersect
SQUARES_SUBTRACT                   :: "\ue659"   // squares-subtract
SQUARES_UNITE                      :: "\ue65a"   // squares-unite
SQUIRCLE                           :: "\ue57a"   // squircle
SQUIRCLE_DASHED                    :: "\ue679"   // squircle-dashed
SQUIRREL                           :: "\ue49f"   // squirrel
STAMP                              :: "\ue3bb"   // stamp
STAR                               :: "\ue176"   // star
STAR_CHECK                         :: "\ue707"   // star-check
STAR_HALF                          :: "\ue20b"   // star-half
STAR_MINUS                         :: "\ue708"   // star-minus
STAR_OFF                           :: "\ue2b0"   // star-off
STAR_PLUS                          :: "\ue709"   // star-plus
STAR_X                             :: "\ue70a"   // star-x
STEP_BACK                          :: "\ue3e9"   // step-back
STEP_FORWARD                       :: "\ue3ea"   // step-forward
STETHOSCOPE                        :: "\ue2f1"   // stethoscope
STICKER                            :: "\ue302"   // sticker
STICKY_NOTE                        :: "\ue303"   // sticky-note
STICKY_NOTE_CHECK                  :: "\ue6f6"   // sticky-note-check
STICKY_NOTE_MINUS                  :: "\ue6f7"   // sticky-note-minus
STICKY_NOTE_OFF                    :: "\ue6f8"   // sticky-note-off
STICKY_NOTE_PLUS                   :: "\ue6f9"   // sticky-note-plus
STICKY_NOTE_X                      :: "\ue6fa"   // sticky-note-x
STICKY_NOTES                       :: "\ue6fb"   // sticky-notes
STONE                              :: "\ue6eb"   // stone
STORE                              :: "\ue3e4"   // store
STRETCH_HORIZONTAL                 :: "\ue27c"   // stretch-horizontal
STRETCH_VERTICAL                   :: "\ue27d"   // stretch-vertical
STRIKETHROUGH                      :: "\ue177"   // strikethrough
SUBSCRIPT                          :: "\ue25c"   // subscript
SUMMARY                            :: "\ue711"   // summary
SUN                                :: "\ue178"   // sun
SUN_DIM                            :: "\ue299"   // sun-dim
SUN_MEDIUM                         :: "\ue2b1"   // sun-medium
SUN_MOON                           :: "\ue2b2"   // sun-moon
SUN_SNOW                           :: "\ue372"   // sun-snow
SUNRISE                            :: "\ue179"   // sunrise
SUNSET                             :: "\ue17a"   // sunset
SUPERSCRIPT                        :: "\ue25e"   // superscript
SWATCH_BOOK                        :: "\ue59f"   // swatch-book
SWISS_FRANC                        :: "\ue17b"   // swiss-franc
SWITCH_CAMERA                      :: "\ue17c"   // switch-camera
SWORD                              :: "\ue2b3"   // sword
SWORDS                             :: "\ue2b4"   // swords
SYRINGE                            :: "\ue2f2"   // syringe
TABLE                              :: "\ue17d"   // table
TABLE_2                            :: "\ue2f9"   // table-2
TABLE_CELLS_MERGE                  :: "\ue5c7"   // table-cells-merge
TABLE_CELLS_SPLIT                  :: "\ue5c8"   // table-cells-split
TABLE_COLUMNS_SPLIT                :: "\ue5c9"   // table-columns-split
TABLE_OF_CONTENTS                  :: "\ue61e"   // table-of-contents
TABLE_PROPERTIES                   :: "\ue4db"   // table-properties
TABLE_ROWS_SPLIT                   :: "\ue5ca"   // table-rows-split
TABLET                             :: "\ue17e"   // tablet
TABLET_SMARTPHONE                  :: "\ue50a"   // tablet-smartphone
TABLETS                            :: "\ue3be"   // tablets
TAG                                :: "\ue17f"   // tag
TAG_PLUS                           :: "\ue712"   // tag-plus
TAG_X                              :: "\ue713"   // tag-x
TAGS                               :: "\ue35c"   // tags
TALLY_1                            :: "\ue4d6"   // tally-1
TALLY_2                            :: "\ue4d7"   // tally-2
TALLY_3                            :: "\ue4d8"   // tally-3
TALLY_4                            :: "\ue4d9"   // tally-4
TALLY_5                            :: "\ue4da"   // tally-5
TANGENT                            :: "\ue52e"   // tangent
TARGET                             :: "\ue180"   // target
TELESCOPE                          :: "\ue5c5"   // telescope
TENT                               :: "\ue227"   // tent
TENT_TREE                          :: "\ue53b"   // tent-tree
TERMINAL                           :: "\ue181"   // terminal
TEST_TUBE                          :: "\ue405"   // test-tube
TEST_TUBE_2                        :: "\ue406"   // test-tube-2
TEST_TUBES                         :: "\ue407"   // test-tubes
TEXT_ALIGN_JUSTIFY_CENTER          :: "\ue795"   // text-align-justify-center
TEXT_ALIGN_JUSTIFY_END             :: "\ue796"   // text-align-justify-end
TEXT_ALIGN_JUSTIFY_START           :: "\ue797"   // text-align-justify-start
TEXT_CURSOR                        :: "\ue264"   // text-cursor
TEXT_CURSOR_INPUT                  :: "\ue265"   // text-cursor-input
TEXT_QUOTE                         :: "\ue49e"   // text-quote
TEXT_SEARCH                        :: "\ue5ad"   // text-search
TEXT_WRAP                          :: "\ue248"   // text-wrap
THEATER                            :: "\ue522"   // theater
THERMOMETER                        :: "\ue186"   // thermometer
THERMOMETER_SNOWFLAKE              :: "\ue187"   // thermometer-snowflake
THERMOMETER_SUN                    :: "\ue188"   // thermometer-sun
THUMBS_DOWN                        :: "\ue189"   // thumbs-down
THUMBS_UP                          :: "\ue18a"   // thumbs-up
TIC_TAC_TOE                        :: "\ue768"   // tic-tac-toe
TICKET                             :: "\ue20f"   // ticket
TICKET_CHECK                       :: "\ue5ae"   // ticket-check
TICKET_MINUS                       :: "\ue5af"   // ticket-minus
TICKET_PERCENT                     :: "\ue5b0"   // ticket-percent
TICKET_PLUS                        :: "\ue5b1"   // ticket-plus
TICKET_SLASH                       :: "\ue5b2"   // ticket-slash
TICKET_X                           :: "\ue5b3"   // ticket-x
TICKETS                            :: "\ue622"   // tickets
TICKETS_PLANE                      :: "\ue623"   // tickets-plane
TIMELINE                           :: "\ue6ec"   // timeline
TIMER                              :: "\ue1e0"   // timer
TIMER_OFF                          :: "\ue249"   // timer-off
TIMER_RESET                        :: "\ue236"   // timer-reset
TOGGLE_LEFT                        :: "\ue18b"   // toggle-left
TOGGLE_RIGHT                       :: "\ue18c"   // toggle-right
TOILET                             :: "\ue635"   // toilet
TOOL_CASE                          :: "\ue67d"   // tool-case
TOOLBOX                            :: "\ue6b0"   // toolbox
TOOTHBRUSH                         :: "\ue76a"   // toothbrush
TOOTHBRUSH_SPARKLES                :: "\ue769"   // toothbrush-sparkles
TORNADO                            :: "\ue218"   // tornado
TORUS                              :: "\ue52f"   // torus
TOUCHPAD                           :: "\ue449"   // touchpad
TOUCHPAD_OFF                       :: "\ue44a"   // touchpad-off
TOWEL_RACK                         :: "\ue6c7"   // towel-rack
TOWER_CONTROL                      :: "\ue3bc"   // tower-control
TOY_BRICK                          :: "\ue347"   // toy-brick
TRACTOR                            :: "\ue504"   // tractor
TRAFFIC_CONE                       :: "\ue505"   // traffic-cone
TRAILER                            :: "\ue742"   // trailer
TRAIN                              :: "\ue2a9"   // train
TRAIN_FRONT                        :: "\ue506"   // train-front
TRAIN_FRONT_TUNNEL                 :: "\ue507"   // train-front-tunnel
TRAIN_TRACK                        :: "\ue508"   // train-track
TRANSGENDER                        :: "\ue644"   // transgender
TRASH_2                            :: "\ue18d"   // trash-2
TRASH_OFF                          :: "\ue763"   // trash-off
TREE_DECIDUOUS                     :: "\ue2f3"   // tree-deciduous
TREE_PINE                          :: "\ue2f4"   // tree-pine
TREES                              :: "\ue2f5"   // trees
TRENDING_DOWN                      :: "\ue190"   // trending-down
TRENDING_UP                        :: "\ue191"   // trending-up
TRENDING_UP_DOWN                   :: "\ue625"   // trending-up-down
TRIANGLE                           :: "\ue192"   // triangle
TRIANGLE_DASHED                    :: "\ue63d"   // triangle-dashed
TRIANGLE_RIGHT                     :: "\ue4ed"   // triangle-right
TROPHY                             :: "\ue373"   // trophy
TRUCK                              :: "\ue194"   // truck
TRUCK_ELECTRIC                     :: "\ue65f"   // truck-electric
TUBE_LOTION                        :: "\ue786"   // tube-lotion
TURKISH_LIRA                       :: "\ue680"   // turkish-lira
TURNTABLE                          :: "\ue68c"   // turntable
TURTLE                             :: "\ue4f9"   // turtle
TV                                 :: "\ue195"   // tv
TV_2                               :: "\ue203"   // tv-2
TV_MINIMAL_PLAY                    :: "\ue5ec"   // tv-minimal-play
TYPE                               :: "\ue198"   // type
TYPE_OUTLINE                       :: "\ue602"   // type-outline
UMBRELLA                           :: "\ue199"   // umbrella
UMBRELLA_OFF                       :: "\ue543"   // umbrella-off
UNDERLINE                          :: "\ue19a"   // underline
UNDO                               :: "\ue19b"   // undo
UNDO_2                             :: "\ue2a1"   // undo-2
UNDO_DOT                           :: "\ue451"   // undo-dot
UNFOLD_HORIZONTAL                  :: "\ue43d"   // unfold-horizontal
UNFOLD_VERTICAL                    :: "\ue43e"   // unfold-vertical
UNGROUP                            :: "\ue467"   // ungroup
UNLINK                             :: "\ue19c"   // unlink
UNLINK_2                           :: "\ue19d"   // unlink-2
UNPLUG                             :: "\ue45d"   // unplug
UPLOAD                             :: "\ue19e"   // upload
USB                                :: "\ue356"   // usb
USB_C_PORT                         :: "\ue73d"   // usb-c-port
USER                               :: "\ue19f"   // user
USER_2                             :: "\ue468"   // user-2
USER_CHECK                         :: "\ue1a0"   // user-check
USER_CHECK_2                       :: "\ue469"   // user-check-2
USER_COG                           :: "\ue342"   // user-cog
USER_COG_2                         :: "\ue46a"   // user-cog-2
USER_GROUP                         :: "\ue764"   // user-group
USER_KEY                           :: "\ue6c8"   // user-key
USER_LOCK                          :: "\ue660"   // user-lock
USER_MINUS                         :: "\ue1a1"   // user-minus
USER_MINUS_2                       :: "\ue46b"   // user-minus-2
USER_PEN                           :: "\ue5fc"   // user-pen
USER_PLUS                          :: "\ue1a2"   // user-plus
USER_PLUS_2                        :: "\ue46c"   // user-plus-2
USER_ROUND_ARROW_LEFT              :: "\ue714"   // user-round-arrow-left
USER_ROUND_GROUP                   :: "\ue765"   // user-round-group
USER_ROUND_KEY                     :: "\ue6c9"   // user-round-key
USER_ROUND_PEN                     :: "\ue5fd"   // user-round-pen
USER_ROUND_SEARCH                  :: "\ue578"   // user-round-search
USER_ROUND_STAR                    :: "\ue7a2"   // user-round-star
USER_ROUND_X                       :: "\ue46d"   // user-round-x
USER_SEARCH                        :: "\ue579"   // user-search
USER_SHIELD                        :: "\ue729"   // user-shield
USER_STAR                          :: "\ue687"   // user-star
USER_X                             :: "\ue1a3"   // user-x
USERS                              :: "\ue1a4"   // users
USERS_2                            :: "\ue46e"   // users-2
UTILITY_POLE                       :: "\ue3c2"   // utility-pole
VAN                                :: "\ue6ad"   // van
VARIABLE                           :: "\ue473"   // variable
VAULT                              :: "\ue58f"   // vault
VECTOR_POLYGON                     :: "\ue74c"   // vector-polygon
VECTOR_SQUARE                      :: "\ue67c"   // vector-square
VEGAN                              :: "\ue39d"   // vegan
VENETIAN_MASK                      :: "\ue2aa"   // venetian-mask
VENUS                              :: "\ue645"   // venus
VENUS_AND_MARS                     :: "\ue646"   // venus-and-mars
VIBRATE                            :: "\ue223"   // vibrate
VIBRATE_OFF                        :: "\ue29d"   // vibrate-off
VIDEO                              :: "\ue1a5"   // video
VIDEO_OFF                          :: "\ue1a6"   // video-off
VIDEOTAPE                          :: "\ue4cb"   // videotape
VIEW                               :: "\ue1a7"   // view
VIRUS                              :: "\ue75d"   // virus
VIRUS_OFF                          :: "\ue75c"   // virus-off
VOICEMAIL                          :: "\ue1a8"   // voicemail
VOLLEYBALL                         :: "\ue62f"   // volleyball
VOLUME                             :: "\ue1a9"   // volume
VOLUME_1                           :: "\ue1aa"   // volume-1
VOLUME_2                           :: "\ue1ab"   // volume-2
VOLUME_OFF                         :: "\ue626"   // volume-off
VOLUME_X                           :: "\ue1ac"   // volume-x
VOTE                               :: "\ue3ad"   // vote
WALLET                             :: "\ue204"   // wallet
WALLET_2                           :: "\ue4cd"   // wallet-2
WALLET_CARDS                       :: "\ue4cc"   // wallet-cards
WALLPAPER                          :: "\ue44b"   // wallpaper
WAND                               :: "\ue246"   // wand
WAND_2                             :: "\ue357"   // wand-2
WAREHOUSE                          :: "\ue3e6"   // warehouse
WASHING_MACHINE                    :: "\ue590"   // washing-machine
WATCH                              :: "\ue1ad"   // watch
WAVES_ARROW_DOWN                   :: "\ue6a9"   // waves-arrow-down
WAVES_ARROW_UP                     :: "\ue6aa"   // waves-arrow-up
WAVES_HORIZONTAL                   :: "\ue283"   // waves-horizontal
WAVES_LADDER                       :: "\ue63b"   // waves-ladder
WAVES_VERTICAL                     :: "\ue6f2"   // waves-vertical
WAYPOINTS                          :: "\ue542"   // waypoints
WEBCAM                             :: "\ue205"   // webcam
WEBCAM_OFF                         :: "\ue6ff"   // webcam-off
WEBHOOK                            :: "\ue374"   // webhook
WEBHOOK_OFF                        :: "\ue5b7"   // webhook-off
WEIGHT                             :: "\ue530"   // weight
WEIGHT_TILDE                       :: "\ue6ae"   // weight-tilde
WHEAT                              :: "\ue39e"   // wheat
WHEAT_OFF                          :: "\ue39f"   // wheat-off
WHISTLE                            :: "\ue74d"   // whistle
WHOLE_WORD                         :: "\ue3df"   // whole-word
WIFI                               :: "\ue1ae"   // wifi
WIFI_COG                           :: "\ue674"   // wifi-cog
WIFI_HIGH                          :: "\ue5f7"   // wifi-high
WIFI_LOCK                          :: "\ue7a3"   // wifi-lock
WIFI_LOW                           :: "\ue5f8"   // wifi-low
WIFI_OFF                           :: "\ue1af"   // wifi-off
WIFI_PEN                           :: "\ue663"   // wifi-pen
WIFI_SYNC                          :: "\ue681"   // wifi-sync
WIFI_ZERO                          :: "\ue5f9"   // wifi-zero
WIND                               :: "\ue1b0"   // wind
WIND_ARROW_DOWN                    :: "\ue631"   // wind-arrow-down
WIND_ARROW_UP                      :: "\ue798"   // wind-arrow-up
WINE                               :: "\ue2f8"   // wine
WINE_OFF                           :: "\ue3a0"   // wine-off
WORKFLOW                           :: "\ue425"   // workflow
WORM                               :: "\ue5da"   // worm
WRENCH                             :: "\ue1b1"   // wrench
WRENCH_OFF                         :: "\ue70b"   // wrench-off
X                                  :: "\ue1b2"   // x
X_LINE_TOP                         :: "\ue6ca"   // x-line-top
ZAP                                :: "\ue1b4"   // zap
ZAP_OFF                            :: "\ue1b5"   // zap-off
ZODIAC_AQUARIUS                    :: "\ue6cb"   // zodiac-aquarius
ZODIAC_ARIES                       :: "\ue6cc"   // zodiac-aries
ZODIAC_CANCER                      :: "\ue6cd"   // zodiac-cancer
ZODIAC_CAPRICORN                   :: "\ue6ce"   // zodiac-capricorn
ZODIAC_GEMINI                      :: "\ue6cf"   // zodiac-gemini
ZODIAC_LEO                         :: "\ue6d0"   // zodiac-leo
ZODIAC_LIBRA                       :: "\ue6d1"   // zodiac-libra
ZODIAC_OPHIUCHUS                   :: "\ue6d2"   // zodiac-ophiuchus
ZODIAC_PISCES                      :: "\ue6d3"   // zodiac-pisces
ZODIAC_SAGITTARIUS                 :: "\ue6d4"   // zodiac-sagittarius
ZODIAC_SCORPIO                     :: "\ue6d5"   // zodiac-scorpio
ZODIAC_TAURUS                      :: "\ue6d6"   // zodiac-taurus
ZODIAC_VIRGO                       :: "\ue6d7"   // zodiac-virgo
ZOOM_IN                            :: "\ue1b6"   // zoom-in
ZOOM_OUT                           :: "\ue1b7"   // zoom-out

// An icon and its name, as the font names its glyph ("arrow-up-down").
Named :: struct {
	name:  string,
	glyph: string,
}

// Every icon by its name, sorted by the bytes of the name: glyph_of's table.
@(rodata)
NAMES := [?]Named{
	{"a-arrow-down", A_ARROW_DOWN},
	{"a-arrow-up", A_ARROW_UP},
	{"a-large-small", A_LARGE_SMALL},
	{"accessibility", ACCESSIBILITY},
	{"activity", ACTIVITY},
	{"activity-square", ACTIVITY_SQUARE},
	{"ad", AD},
	{"air-vent", AIR_VENT},
	{"airplay", AIRPLAY},
	{"alarm-check", ALARM_CHECK},
	{"alarm-clock", ALARM_CLOCK},
	{"alarm-clock-minus", ALARM_CLOCK_MINUS},
	{"alarm-clock-off", ALARM_CLOCK_OFF},
	{"alarm-clock-plus", ALARM_CLOCK_PLUS},
	{"alarm-smoke", ALARM_SMOKE},
	{"album", ALBUM},
	{"alert-circle", ALERT_CIRCLE},
	{"alert-octagon", ALERT_OCTAGON},
	{"alert-triangle", ALERT_TRIANGLE},
	{"align-center", ALIGN_CENTER},
	{"align-center-horizontal", ALIGN_CENTER_HORIZONTAL},
	{"align-center-vertical", ALIGN_CENTER_VERTICAL},
	{"align-end-horizontal", ALIGN_END_HORIZONTAL},
	{"align-end-vertical", ALIGN_END_VERTICAL},
	{"align-horizontal-distribute-center", ALIGN_HORIZONTAL_DISTRIBUTE_CENTER},
	{"align-horizontal-distribute-end", ALIGN_HORIZONTAL_DISTRIBUTE_END},
	{"align-horizontal-distribute-start", ALIGN_HORIZONTAL_DISTRIBUTE_START},
	{"align-horizontal-justify-center", ALIGN_HORIZONTAL_JUSTIFY_CENTER},
	{"align-horizontal-justify-end", ALIGN_HORIZONTAL_JUSTIFY_END},
	{"align-horizontal-justify-start", ALIGN_HORIZONTAL_JUSTIFY_START},
	{"align-horizontal-space-around", ALIGN_HORIZONTAL_SPACE_AROUND},
	{"align-horizontal-space-between", ALIGN_HORIZONTAL_SPACE_BETWEEN},
	{"align-justify", ALIGN_JUSTIFY},
	{"align-left", ALIGN_LEFT},
	{"align-right", ALIGN_RIGHT},
	{"align-start-horizontal", ALIGN_START_HORIZONTAL},
	{"align-start-vertical", ALIGN_START_VERTICAL},
	{"align-vertical-distribute-center", ALIGN_VERTICAL_DISTRIBUTE_CENTER},
	{"align-vertical-distribute-end", ALIGN_VERTICAL_DISTRIBUTE_END},
	{"align-vertical-distribute-start", ALIGN_VERTICAL_DISTRIBUTE_START},
	{"align-vertical-justify-center", ALIGN_VERTICAL_JUSTIFY_CENTER},
	{"align-vertical-justify-end", ALIGN_VERTICAL_JUSTIFY_END},
	{"align-vertical-justify-start", ALIGN_VERTICAL_JUSTIFY_START},
	{"align-vertical-space-around", ALIGN_VERTICAL_SPACE_AROUND},
	{"align-vertical-space-between", ALIGN_VERTICAL_SPACE_BETWEEN},
	{"ambulance", AMBULANCE},
	{"ampersand", AMPERSAND},
	{"ampersands", AMPERSANDS},
	{"amphora", AMPHORA},
	{"anchor", ANCHOR},
	{"angle", ANGLE},
	{"angry", ANGRY},
	{"annoyed", ANNOYED},
	{"antenna", ANTENNA},
	{"anvil", ANVIL},
	{"aperture", APERTURE},
	{"app-window", APP_WINDOW},
	{"app-window-mac", APP_WINDOW_MAC},
	{"apple", APPLE},
	{"archive", ARCHIVE},
	{"archive-restore", ARCHIVE_RESTORE},
	{"archive-x", ARCHIVE_X},
	{"area-chart", AREA_CHART},
	{"armchair", ARMCHAIR},
	{"armenian-dram", ARMENIAN_DRAM},
	{"arrow-big-down", ARROW_BIG_DOWN},
	{"arrow-big-down-dash", ARROW_BIG_DOWN_DASH},
	{"arrow-big-left", ARROW_BIG_LEFT},
	{"arrow-big-left-dash", ARROW_BIG_LEFT_DASH},
	{"arrow-big-right", ARROW_BIG_RIGHT},
	{"arrow-big-right-dash", ARROW_BIG_RIGHT_DASH},
	{"arrow-big-up", ARROW_BIG_UP},
	{"arrow-big-up-dash", ARROW_BIG_UP_DASH},
	{"arrow-down", ARROW_DOWN},
	{"arrow-down-0-1", ARROW_DOWN_0_1},
	{"arrow-down-1-0", ARROW_DOWN_1_0},
	{"arrow-down-a-z", ARROW_DOWN_A_Z},
	{"arrow-down-circle", ARROW_DOWN_CIRCLE},
	{"arrow-down-from-line", ARROW_DOWN_FROM_LINE},
	{"arrow-down-left", ARROW_DOWN_LEFT},
	{"arrow-down-left-from-circle", ARROW_DOWN_LEFT_FROM_CIRCLE},
	{"arrow-down-left-from-square", ARROW_DOWN_LEFT_FROM_SQUARE},
	{"arrow-down-left-square", ARROW_DOWN_LEFT_SQUARE},
	{"arrow-down-narrow-wide", ARROW_DOWN_NARROW_WIDE},
	{"arrow-down-right", ARROW_DOWN_RIGHT},
	{"arrow-down-right-from-circle", ARROW_DOWN_RIGHT_FROM_CIRCLE},
	{"arrow-down-right-from-square", ARROW_DOWN_RIGHT_FROM_SQUARE},
	{"arrow-down-right-square", ARROW_DOWN_RIGHT_SQUARE},
	{"arrow-down-square", ARROW_DOWN_SQUARE},
	{"arrow-down-to-dot", ARROW_DOWN_TO_DOT},
	{"arrow-down-to-line", ARROW_DOWN_TO_LINE},
	{"arrow-down-up", ARROW_DOWN_UP},
	{"arrow-down-wide-narrow", ARROW_DOWN_WIDE_NARROW},
	{"arrow-down-z-a", ARROW_DOWN_Z_A},
	{"arrow-left", ARROW_LEFT},
	{"arrow-left-circle", ARROW_LEFT_CIRCLE},
	{"arrow-left-from-line", ARROW_LEFT_FROM_LINE},
	{"arrow-left-right", ARROW_LEFT_RIGHT},
	{"arrow-left-square", ARROW_LEFT_SQUARE},
	{"arrow-left-to-line", ARROW_LEFT_TO_LINE},
	{"arrow-right", ARROW_RIGHT},
	{"arrow-right-circle", ARROW_RIGHT_CIRCLE},
	{"arrow-right-from-line", ARROW_RIGHT_FROM_LINE},
	{"arrow-right-left", ARROW_RIGHT_LEFT},
	{"arrow-right-square", ARROW_RIGHT_SQUARE},
	{"arrow-right-to-line", ARROW_RIGHT_TO_LINE},
	{"arrow-up", ARROW_UP},
	{"arrow-up-0-1", ARROW_UP_0_1},
	{"arrow-up-1-0", ARROW_UP_1_0},
	{"arrow-up-a-z", ARROW_UP_A_Z},
	{"arrow-up-circle", ARROW_UP_CIRCLE},
	{"arrow-up-down", ARROW_UP_DOWN},
	{"arrow-up-from-dot", ARROW_UP_FROM_DOT},
	{"arrow-up-from-line", ARROW_UP_FROM_LINE},
	{"arrow-up-left", ARROW_UP_LEFT},
	{"arrow-up-left-from-circle", ARROW_UP_LEFT_FROM_CIRCLE},
	{"arrow-up-left-from-square", ARROW_UP_LEFT_FROM_SQUARE},
	{"arrow-up-left-square", ARROW_UP_LEFT_SQUARE},
	{"arrow-up-narrow-wide", ARROW_UP_NARROW_WIDE},
	{"arrow-up-right", ARROW_UP_RIGHT},
	{"arrow-up-right-from-circle", ARROW_UP_RIGHT_FROM_CIRCLE},
	{"arrow-up-right-from-square", ARROW_UP_RIGHT_FROM_SQUARE},
	{"arrow-up-right-square", ARROW_UP_RIGHT_SQUARE},
	{"arrow-up-square", ARROW_UP_SQUARE},
	{"arrow-up-to-line", ARROW_UP_TO_LINE},
	{"arrow-up-wide-narrow", ARROW_UP_WIDE_NARROW},
	{"arrow-up-z-a", ARROW_UP_Z_A},
	{"arrows-up-from-line", ARROWS_UP_FROM_LINE},
	{"asterisk", ASTERISK},
	{"asterisk-square", ASTERISK_SQUARE},
	{"astroid", ASTROID},
	{"at-sign", AT_SIGN},
	{"atom", ATOM},
	{"audio-lines", AUDIO_LINES},
	{"audio-lines-off", AUDIO_LINES_OFF},
	{"audio-lines-x", AUDIO_LINES_X},
	{"audio-waveform", AUDIO_WAVEFORM},
	{"award", AWARD},
	{"axe", AXE},
	{"axis-3-d", AXIS_3_D},
	{"baby", BABY},
	{"backpack", BACKPACK},
	{"badge", BADGE},
	{"badge-alert", BADGE_ALERT},
	{"badge-cent", BADGE_CENT},
	{"badge-check", BADGE_CHECK},
	{"badge-dollar-sign", BADGE_DOLLAR_SIGN},
	{"badge-euro", BADGE_EURO},
	{"badge-help", BADGE_HELP},
	{"badge-indian-rupee", BADGE_INDIAN_RUPEE},
	{"badge-info", BADGE_INFO},
	{"badge-japanese-yen", BADGE_JAPANESE_YEN},
	{"badge-minus", BADGE_MINUS},
	{"badge-percent", BADGE_PERCENT},
	{"badge-plus", BADGE_PLUS},
	{"badge-pound-sterling", BADGE_POUND_STERLING},
	{"badge-russian-ruble", BADGE_RUSSIAN_RUBLE},
	{"badge-swiss-franc", BADGE_SWISS_FRANC},
	{"badge-turkish-lira", BADGE_TURKISH_LIRA},
	{"badge-x", BADGE_X},
	{"baggage-claim", BAGGAGE_CLAIM},
	{"balloon", BALLOON},
	{"ban", BAN},
	{"banana", BANANA},
	{"bandage", BANDAGE},
	{"bangladeshi-taka", BANGLADESHI_TAKA},
	{"banknote", BANKNOTE},
	{"banknote-arrow-down", BANKNOTE_ARROW_DOWN},
	{"banknote-arrow-up", BANKNOTE_ARROW_UP},
	{"banknote-check", BANKNOTE_CHECK},
	{"banknote-x", BANKNOTE_X},
	{"bar-chart", BAR_CHART},
	{"bar-chart-2", BAR_CHART_2},
	{"bar-chart-3", BAR_CHART_3},
	{"bar-chart-4", BAR_CHART_4},
	{"bar-chart-big", BAR_CHART_BIG},
	{"bar-chart-horizontal", BAR_CHART_HORIZONTAL},
	{"bar-chart-horizontal-big", BAR_CHART_HORIZONTAL_BIG},
	{"barcode", BARCODE},
	{"barrel", BARREL},
	{"baseline", BASELINE},
	{"bath", BATH},
	{"battery", BATTERY},
	{"battery-charging", BATTERY_CHARGING},
	{"battery-full", BATTERY_FULL},
	{"battery-low", BATTERY_LOW},
	{"battery-medium", BATTERY_MEDIUM},
	{"battery-plus", BATTERY_PLUS},
	{"battery-warning", BATTERY_WARNING},
	{"beaker", BEAKER},
	{"bean", BEAN},
	{"bean-off", BEAN_OFF},
	{"bed", BED},
	{"bed-double", BED_DOUBLE},
	{"bed-single", BED_SINGLE},
	{"beef", BEEF},
	{"beef-off", BEEF_OFF},
	{"beer", BEER},
	{"beer-off", BEER_OFF},
	{"bell", BELL},
	{"bell-check", BELL_CHECK},
	{"bell-dot", BELL_DOT},
	{"bell-electric", BELL_ELECTRIC},
	{"bell-minus", BELL_MINUS},
	{"bell-off", BELL_OFF},
	{"bell-plus", BELL_PLUS},
	{"bell-ring", BELL_RING},
	{"between-horizonal-end", BETWEEN_HORIZONAL_END},
	{"between-horizonal-start", BETWEEN_HORIZONAL_START},
	{"between-vertical-end", BETWEEN_VERTICAL_END},
	{"between-vertical-start", BETWEEN_VERTICAL_START},
	{"biceps-flexed", BICEPS_FLEXED},
	{"bike", BIKE},
	{"binary", BINARY},
	{"binoculars", BINOCULARS},
	{"biohazard", BIOHAZARD},
	{"bird", BIRD},
	{"birdhouse", BIRDHOUSE},
	{"bitcoin", BITCOIN},
	{"blend", BLEND},
	{"blender", BLENDER},
	{"blinds", BLINDS},
	{"blocks", BLOCKS},
	{"bluetooth", BLUETOOTH},
	{"bluetooth-connected", BLUETOOTH_CONNECTED},
	{"bluetooth-off", BLUETOOTH_OFF},
	{"bluetooth-searching", BLUETOOTH_SEARCHING},
	{"bold", BOLD},
	{"bolt", BOLT},
	{"bomb", BOMB},
	{"bone", BONE},
	{"bone-fracture", BONE_FRACTURE},
	{"book", BOOK},
	{"book-a", BOOK_A},
	{"book-alert", BOOK_ALERT},
	{"book-audio", BOOK_AUDIO},
	{"book-bookmark", BOOK_BOOKMARK},
	{"book-check", BOOK_CHECK},
	{"book-copy", BOOK_COPY},
	{"book-dashed", BOOK_DASHED},
	{"book-down", BOOK_DOWN},
	{"book-headphones", BOOK_HEADPHONES},
	{"book-heart", BOOK_HEART},
	{"book-image", BOOK_IMAGE},
	{"book-key", BOOK_KEY},
	{"book-lock", BOOK_LOCK},
	{"book-minus", BOOK_MINUS},
	{"book-open", BOOK_OPEN},
	{"book-open-check", BOOK_OPEN_CHECK},
	{"book-open-text", BOOK_OPEN_TEXT},
	{"book-plus", BOOK_PLUS},
	{"book-search", BOOK_SEARCH},
	{"book-text", BOOK_TEXT},
	{"book-type", BOOK_TYPE},
	{"book-up", BOOK_UP},
	{"book-up-2", BOOK_UP_2},
	{"book-user", BOOK_USER},
	{"book-x", BOOK_X},
	{"bookmark", BOOKMARK},
	{"bookmark-check", BOOKMARK_CHECK},
	{"bookmark-minus", BOOKMARK_MINUS},
	{"bookmark-off", BOOKMARK_OFF},
	{"bookmark-plus", BOOKMARK_PLUS},
	{"bookmark-x", BOOKMARK_X},
	{"boom-box", BOOM_BOX},
	{"bot", BOT},
	{"bot-message-square", BOT_MESSAGE_SQUARE},
	{"bot-off", BOT_OFF},
	{"bottle-wine", BOTTLE_WINE},
	{"bow-arrow", BOW_ARROW},
	{"box", BOX},
	{"box-select", BOX_SELECT},
	{"boxes", BOXES},
	{"braces", BRACES},
	{"brackets", BRACKETS},
	{"brain", BRAIN},
	{"brain-circuit", BRAIN_CIRCUIT},
	{"brain-cog", BRAIN_COG},
	{"brick-wall", BRICK_WALL},
	{"brick-wall-fire", BRICK_WALL_FIRE},
	{"brick-wall-shield", BRICK_WALL_SHIELD},
	{"bridge", BRIDGE},
	{"briefcase", BRIEFCASE},
	{"briefcase-business", BRIEFCASE_BUSINESS},
	{"briefcase-conveyor-belt", BRIEFCASE_CONVEYOR_BELT},
	{"briefcase-medical", BRIEFCASE_MEDICAL},
	{"briefcase-plus", BRIEFCASE_PLUS},
	{"bring-to-front", BRING_TO_FRONT},
	{"broccoli", BROCCOLI},
	{"broom", BROOM},
	{"broom-sparkles", BROOM_SPARKLES},
	{"brush", BRUSH},
	{"brush-cleaning", BRUSH_CLEANING},
	{"bubbles", BUBBLES},
	{"bug", BUG},
	{"bug-off", BUG_OFF},
	{"bug-play", BUG_PLAY},
	{"building", BUILDING},
	{"building-2", BUILDING_2},
	{"building-complex-plus", BUILDING_COMPLEX_PLUS},
	{"bus", BUS},
	{"bus-front", BUS_FRONT},
	{"cable", CABLE},
	{"cable-car", CABLE_CAR},
	{"cake", CAKE},
	{"cake-slice", CAKE_SLICE},
	{"calculator", CALCULATOR},
	{"calendar", CALENDAR},
	{"calendar-1", CALENDAR_1},
	{"calendar-arrow-down", CALENDAR_ARROW_DOWN},
	{"calendar-arrow-up", CALENDAR_ARROW_UP},
	{"calendar-check", CALENDAR_CHECK},
	{"calendar-check-2", CALENDAR_CHECK_2},
	{"calendar-chevrons-right", CALENDAR_CHEVRONS_RIGHT},
	{"calendar-clock", CALENDAR_CLOCK},
	{"calendar-cog", CALENDAR_COG},
	{"calendar-days", CALENDAR_DAYS},
	{"calendar-fold", CALENDAR_FOLD},
	{"calendar-heart", CALENDAR_HEART},
	{"calendar-minus", CALENDAR_MINUS},
	{"calendar-minus-2", CALENDAR_MINUS_2},
	{"calendar-off", CALENDAR_OFF},
	{"calendar-plus", CALENDAR_PLUS},
	{"calendar-plus-2", CALENDAR_PLUS_2},
	{"calendar-range", CALENDAR_RANGE},
	{"calendar-search", CALENDAR_SEARCH},
	{"calendar-sync", CALENDAR_SYNC},
	{"calendar-x", CALENDAR_X},
	{"calendar-x-2", CALENDAR_X_2},
	{"calendars", CALENDARS},
	{"camera", CAMERA},
	{"camera-off", CAMERA_OFF},
	{"can", CAN},
	{"can-soda", CAN_SODA},
	{"candlestick-chart", CANDLESTICK_CHART},
	{"candy", CANDY},
	{"candy-cane", CANDY_CANE},
	{"candy-off", CANDY_OFF},
	{"cannabis", CANNABIS},
	{"cannabis-off", CANNABIS_OFF},
	{"captions", CAPTIONS},
	{"captions-off", CAPTIONS_OFF},
	{"car", CAR},
	{"car-battery", CAR_BATTERY},
	{"car-front", CAR_FRONT},
	{"car-taxi-front", CAR_TAXI_FRONT},
	{"caravan", CARAVAN},
	{"card-sim", CARD_SIM},
	{"carrot", CARROT},
	{"carton", CARTON},
	{"carton-off", CARTON_OFF},
	{"case-lower", CASE_LOWER},
	{"case-sensitive", CASE_SENSITIVE},
	{"case-upper", CASE_UPPER},
	{"cassette-tape", CASSETTE_TAPE},
	{"cast", CAST},
	{"castle", CASTLE},
	{"cat", CAT},
	{"cctv", CCTV},
	{"cctv-off", CCTV_OFF},
	{"chart-bar-decreasing", CHART_BAR_DECREASING},
	{"chart-bar-increasing", CHART_BAR_INCREASING},
	{"chart-bar-stacked", CHART_BAR_STACKED},
	{"chart-column-decreasing", CHART_COLUMN_DECREASING},
	{"chart-column-stacked", CHART_COLUMN_STACKED},
	{"chart-gantt", CHART_GANTT},
	{"chart-line", CHART_LINE},
	{"chart-network", CHART_NETWORK},
	{"chart-no-axes-column-decreasing", CHART_NO_AXES_COLUMN_DECREASING},
	{"chart-no-axes-combined", CHART_NO_AXES_COMBINED},
	{"chart-no-axes-gantt", CHART_NO_AXES_GANTT},
	{"chart-pie", CHART_PIE},
	{"chart-scatter", CHART_SCATTER},
	{"chart-spline", CHART_SPLINE},
	{"check", CHECK},
	{"check-check", CHECK_CHECK},
	{"check-circle", CHECK_CIRCLE},
	{"check-circle-2", CHECK_CIRCLE_2},
	{"check-line", CHECK_LINE},
	{"check-square", CHECK_SQUARE},
	{"check-square-2", CHECK_SQUARE_2},
	{"chef-hat", CHEF_HAT},
	{"cherry", CHERRY},
	{"chess-bishop", CHESS_BISHOP},
	{"chess-king", CHESS_KING},
	{"chess-knight", CHESS_KNIGHT},
	{"chess-pawn", CHESS_PAWN},
	{"chess-queen", CHESS_QUEEN},
	{"chess-rook", CHESS_ROOK},
	{"chevron-down", CHEVRON_DOWN},
	{"chevron-down-circle", CHEVRON_DOWN_CIRCLE},
	{"chevron-down-square", CHEVRON_DOWN_SQUARE},
	{"chevron-first", CHEVRON_FIRST},
	{"chevron-last", CHEVRON_LAST},
	{"chevron-left", CHEVRON_LEFT},
	{"chevron-left-circle", CHEVRON_LEFT_CIRCLE},
	{"chevron-left-square", CHEVRON_LEFT_SQUARE},
	{"chevron-right", CHEVRON_RIGHT},
	{"chevron-right-circle", CHEVRON_RIGHT_CIRCLE},
	{"chevron-right-square", CHEVRON_RIGHT_SQUARE},
	{"chevron-up", CHEVRON_UP},
	{"chevron-up-circle", CHEVRON_UP_CIRCLE},
	{"chevron-up-square", CHEVRON_UP_SQUARE},
	{"chevrons-down", CHEVRONS_DOWN},
	{"chevrons-down-up", CHEVRONS_DOWN_UP},
	{"chevrons-left", CHEVRONS_LEFT},
	{"chevrons-left-right", CHEVRONS_LEFT_RIGHT},
	{"chevrons-left-right-ellipsis", CHEVRONS_LEFT_RIGHT_ELLIPSIS},
	{"chevrons-right", CHEVRONS_RIGHT},
	{"chevrons-right-left", CHEVRONS_RIGHT_LEFT},
	{"chevrons-up", CHEVRONS_UP},
	{"chevrons-up-down", CHEVRONS_UP_DOWN},
	{"church", CHURCH},
	{"cigarette", CIGARETTE},
	{"cigarette-off", CIGARETTE_OFF},
	{"circle", CIRCLE},
	{"circle-dashed", CIRCLE_DASHED},
	{"circle-dashed-check", CIRCLE_DASHED_CHECK},
	{"circle-divide", CIRCLE_DIVIDE},
	{"circle-dollar-sign", CIRCLE_DOLLAR_SIGN},
	{"circle-dot", CIRCLE_DOT},
	{"circle-dot-dashed", CIRCLE_DOT_DASHED},
	{"circle-ellipsis", CIRCLE_ELLIPSIS},
	{"circle-equal", CIRCLE_EQUAL},
	{"circle-euro", CIRCLE_EURO},
	{"circle-fading-arrow-up", CIRCLE_FADING_ARROW_UP},
	{"circle-fading-plus", CIRCLE_FADING_PLUS},
	{"circle-gauge", CIRCLE_GAUGE},
	{"circle-help", CIRCLE_HELP},
	{"circle-minus", CIRCLE_MINUS},
	{"circle-off", CIRCLE_OFF},
	{"circle-parking", CIRCLE_PARKING},
	{"circle-parking-off", CIRCLE_PARKING_OFF},
	{"circle-pause", CIRCLE_PAUSE},
	{"circle-percent", CIRCLE_PERCENT},
	{"circle-pile", CIRCLE_PILE},
	{"circle-play", CIRCLE_PLAY},
	{"circle-plus", CIRCLE_PLUS},
	{"circle-pound-sterling", CIRCLE_POUND_STERLING},
	{"circle-power", CIRCLE_POWER},
	{"circle-slash", CIRCLE_SLASH},
	{"circle-slash-2", CIRCLE_SLASH_2},
	{"circle-small", CIRCLE_SMALL},
	{"circle-star", CIRCLE_STAR},
	{"circle-stop", CIRCLE_STOP},
	{"circle-user", CIRCLE_USER},
	{"circle-user-round", CIRCLE_USER_ROUND},
	{"circle-x", CIRCLE_X},
	{"circuit-board", CIRCUIT_BOARD},
	{"citrus", CITRUS},
	{"clapperboard", CLAPPERBOARD},
	{"clef-alto", CLEF_ALTO},
	{"clef-bass", CLEF_BASS},
	{"clef-treble", CLEF_TREBLE},
	{"clipboard", CLIPBOARD},
	{"clipboard-check", CLIPBOARD_CHECK},
	{"clipboard-clock", CLIPBOARD_CLOCK},
	{"clipboard-copy", CLIPBOARD_COPY},
	{"clipboard-edit", CLIPBOARD_EDIT},
	{"clipboard-list", CLIPBOARD_LIST},
	{"clipboard-minus", CLIPBOARD_MINUS},
	{"clipboard-paste", CLIPBOARD_PASTE},
	{"clipboard-pen-line", CLIPBOARD_PEN_LINE},
	{"clipboard-plus", CLIPBOARD_PLUS},
	{"clipboard-type", CLIPBOARD_TYPE},
	{"clipboard-x", CLIPBOARD_X},
	{"clock-1", CLOCK_1},
	{"clock-10", CLOCK_10},
	{"clock-11", CLOCK_11},
	{"clock-12", CLOCK_12},
	{"clock-2", CLOCK_2},
	{"clock-3", CLOCK_3},
	{"clock-4", CLOCK_4},
	{"clock-5", CLOCK_5},
	{"clock-6", CLOCK_6},
	{"clock-7", CLOCK_7},
	{"clock-8", CLOCK_8},
	{"clock-9", CLOCK_9},
	{"clock-alert", CLOCK_ALERT},
	{"clock-arrow-down", CLOCK_ARROW_DOWN},
	{"clock-arrow-left", CLOCK_ARROW_LEFT},
	{"clock-arrow-right", CLOCK_ARROW_RIGHT},
	{"clock-arrow-up", CLOCK_ARROW_UP},
	{"clock-check", CLOCK_CHECK},
	{"clock-fading", CLOCK_FADING},
	{"clock-plus", CLOCK_PLUS},
	{"closed-caption", CLOSED_CAPTION},
	{"cloud", CLOUD},
	{"cloud-alert", CLOUD_ALERT},
	{"cloud-backup", CLOUD_BACKUP},
	{"cloud-check", CLOUD_CHECK},
	{"cloud-cog", CLOUD_COG},
	{"cloud-download", CLOUD_DOWNLOAD},
	{"cloud-drizzle", CLOUD_DRIZZLE},
	{"cloud-fog", CLOUD_FOG},
	{"cloud-hail", CLOUD_HAIL},
	{"cloud-lightning", CLOUD_LIGHTNING},
	{"cloud-moon", CLOUD_MOON},
	{"cloud-moon-rain", CLOUD_MOON_RAIN},
	{"cloud-off", CLOUD_OFF},
	{"cloud-rain", CLOUD_RAIN},
	{"cloud-rain-wind", CLOUD_RAIN_WIND},
	{"cloud-snow", CLOUD_SNOW},
	{"cloud-sun", CLOUD_SUN},
	{"cloud-sun-rain", CLOUD_SUN_RAIN},
	{"cloud-sync", CLOUD_SYNC},
	{"cloud-upload", CLOUD_UPLOAD},
	{"cloudy", CLOUDY},
	{"clover", CLOVER},
	{"club", CLUB},
	{"code", CODE},
	{"code-2", CODE_2},
	{"code-square", CODE_SQUARE},
	{"coffee", COFFEE},
	{"cog", COG},
	{"coins", COINS},
	{"columns-2", COLUMNS_2},
	{"columns-3", COLUMNS_3},
	{"columns-3-cog", COLUMNS_3_COG},
	{"columns-4", COLUMNS_4},
	{"combine", COMBINE},
	{"command", COMMAND},
	{"compass", COMPASS},
	{"component", COMPONENT},
	{"computer", COMPUTER},
	{"concierge-bell", CONCIERGE_BELL},
	{"cone", CONE},
	{"construction", CONSTRUCTION},
	{"contact", CONTACT},
	{"contact-2", CONTACT_2},
	{"container", CONTAINER},
	{"contrast", CONTRAST},
	{"cookie", COOKIE},
	{"cooking-pot", COOKING_POT},
	{"copy", COPY},
	{"copy-check", COPY_CHECK},
	{"copy-minus", COPY_MINUS},
	{"copy-plus", COPY_PLUS},
	{"copy-slash", COPY_SLASH},
	{"copy-x", COPY_X},
	{"copyleft", COPYLEFT},
	{"copyright", COPYRIGHT},
	{"corner-down-left", CORNER_DOWN_LEFT},
	{"corner-down-right", CORNER_DOWN_RIGHT},
	{"corner-left-down", CORNER_LEFT_DOWN},
	{"corner-left-up", CORNER_LEFT_UP},
	{"corner-right-down", CORNER_RIGHT_DOWN},
	{"corner-right-up", CORNER_RIGHT_UP},
	{"corner-up-left", CORNER_UP_LEFT},
	{"corner-up-right", CORNER_UP_RIGHT},
	{"cpu", CPU},
	{"creative-commons", CREATIVE_COMMONS},
	{"credit-card", CREDIT_CARD},
	{"credit-card-check", CREDIT_CARD_CHECK},
	{"credit-card-minus", CREDIT_CARD_MINUS},
	{"credit-card-plus", CREDIT_CARD_PLUS},
	{"credit-card-reader", CREDIT_CARD_READER},
	{"credit-card-x", CREDIT_CARD_X},
	{"croissant", CROISSANT},
	{"crop", CROP},
	{"cross", CROSS},
	{"crosshair", CROSSHAIR},
	{"crown", CROWN},
	{"cuboid", CUBOID},
	{"cup-soda", CUP_SODA},
	{"cupcake", CUPCAKE},
	{"currency", CURRENCY},
	{"cylinder", CYLINDER},
	{"dam", DAM},
	{"database", DATABASE},
	{"database-arrow-down", DATABASE_ARROW_DOWN},
	{"database-arrow-up", DATABASE_ARROW_UP},
	{"database-backup", DATABASE_BACKUP},
	{"database-check", DATABASE_CHECK},
	{"database-minus", DATABASE_MINUS},
	{"database-plus", DATABASE_PLUS},
	{"database-search", DATABASE_SEARCH},
	{"database-x", DATABASE_X},
	{"database-zap", DATABASE_ZAP},
	{"decimals-arrow-left", DECIMALS_ARROW_LEFT},
	{"decimals-arrow-right", DECIMALS_ARROW_RIGHT},
	{"delete", DELETE},
	{"dessert", DESSERT},
	{"diameter", DIAMETER},
	{"diamond", DIAMOND},
	{"diamond-minus", DIAMOND_MINUS},
	{"diamond-percent", DIAMOND_PERCENT},
	{"diamond-plus", DIAMOND_PLUS},
	{"dice-1", DICE_1},
	{"dice-2", DICE_2},
	{"dice-3", DICE_3},
	{"dice-4", DICE_4},
	{"dice-5", DICE_5},
	{"dice-6", DICE_6},
	{"dices", DICES},
	{"diff", DIFF},
	{"disc", DISC},
	{"disc-2", DISC_2},
	{"disc-3", DISC_3},
	{"disc-album", DISC_ALBUM},
	{"divide", DIVIDE},
	{"divide-square", DIVIDE_SQUARE},
	{"dna", DNA},
	{"dna-off", DNA_OFF},
	{"dock", DOCK},
	{"dog", DOG},
	{"dollar-sign", DOLLAR_SIGN},
	{"dome", DOME},
	{"donut", DONUT},
	{"door-closed", DOOR_CLOSED},
	{"door-closed-cog", DOOR_CLOSED_COG},
	{"door-closed-locked", DOOR_CLOSED_LOCKED},
	{"door-closed-package", DOOR_CLOSED_PACKAGE},
	{"door-open", DOOR_OPEN},
	{"door-stairwell", DOOR_STAIRWELL},
	{"dot", DOT},
	{"dot-square", DOT_SQUARE},
	{"download", DOWNLOAD},
	{"drafting-compass", DRAFTING_COMPASS},
	{"drama", DRAMA},
	{"drill", DRILL},
	{"drone", DRONE},
	{"droplet", DROPLET},
	{"droplet-off", DROPLET_OFF},
	{"droplets", DROPLETS},
	{"drum", DRUM},
	{"drumstick", DRUMSTICK},
	{"dumbbell", DUMBBELL},
	{"ear", EAR},
	{"ear-off", EAR_OFF},
	{"earth", EARTH},
	{"earth-lock", EARTH_LOCK},
	{"eclipse", ECLIPSE},
	{"edit", EDIT},
	{"edit-2", EDIT_2},
	{"edit-3", EDIT_3},
	{"egg", EGG},
	{"egg-fried", EGG_FRIED},
	{"egg-off", EGG_OFF},
	{"eject", EJECT},
	{"ellipse", ELLIPSE},
	{"ellipsis", ELLIPSIS},
	{"ellipsis-vertical", ELLIPSIS_VERTICAL},
	{"engine", ENGINE},
	{"equal", EQUAL},
	{"equal-approximately", EQUAL_APPROXIMATELY},
	{"equal-approximately-not", EQUAL_APPROXIMATELY_NOT},
	{"equal-not", EQUAL_NOT},
	{"equal-square", EQUAL_SQUARE},
	{"eraser", ERASER},
	{"ethernet-port", ETHERNET_PORT},
	{"euro", EURO},
	{"ev-charger", EV_CHARGER},
	{"expand", EXPAND},
	{"external-link", EXTERNAL_LINK},
	{"eye", EYE},
	{"eye-closed", EYE_CLOSED},
	{"eye-dashed", EYE_DASHED},
	{"eye-off", EYE_OFF},
	{"face-grinning", FACE_GRINNING},
	{"face-neutral", FACE_NEUTRAL},
	{"face-slightly-frowning", FACE_SLIGHTLY_FROWNING},
	{"face-slightly-smiling", FACE_SLIGHTLY_SMILING},
	{"face-slightly-smiling-plus", FACE_SLIGHTLY_SMILING_PLUS},
	{"factory", FACTORY},
	{"fan", FAN},
	{"fast-forward", FAST_FORWARD},
	{"faucet", FAUCET},
	{"feather", FEATHER},
	{"fence", FENCE},
	{"ferris-wheel", FERRIS_WHEEL},
	{"file", FILE},
	{"file-archive", FILE_ARCHIVE},
	{"file-audio-2", FILE_AUDIO_2},
	{"file-axis-3-d", FILE_AXIS_3_D},
	{"file-badge-2", FILE_BADGE_2},
	{"file-bar-chart", FILE_BAR_CHART},
	{"file-bar-chart-2", FILE_BAR_CHART_2},
	{"file-box", FILE_BOX},
	{"file-braces", FILE_BRACES},
	{"file-braces-corner", FILE_BRACES_CORNER},
	{"file-chart-line", FILE_CHART_LINE},
	{"file-chart-pie", FILE_CHART_PIE},
	{"file-check", FILE_CHECK},
	{"file-check-2", FILE_CHECK_2},
	{"file-clock", FILE_CLOCK},
	{"file-code", FILE_CODE},
	{"file-code-2", FILE_CODE_2},
	{"file-cog-2", FILE_COG_2},
	{"file-diff", FILE_DIFF},
	{"file-digit", FILE_DIGIT},
	{"file-down", FILE_DOWN},
	{"file-edit", FILE_EDIT},
	{"file-exclamation-point", FILE_EXCLAMATION_POINT},
	{"file-heart", FILE_HEART},
	{"file-image", FILE_IMAGE},
	{"file-input", FILE_INPUT},
	{"file-key-2", FILE_KEY_2},
	{"file-lock-2", FILE_LOCK_2},
	{"file-minus", FILE_MINUS},
	{"file-minus-2", FILE_MINUS_2},
	{"file-music", FILE_MUSIC},
	{"file-output", FILE_OUTPUT},
	{"file-pen-line", FILE_PEN_LINE},
	{"file-play", FILE_PLAY},
	{"file-plus", FILE_PLUS},
	{"file-plus-2", FILE_PLUS_2},
	{"file-question-mark", FILE_QUESTION_MARK},
	{"file-scan", FILE_SCAN},
	{"file-search", FILE_SEARCH},
	{"file-search-2", FILE_SEARCH_2},
	{"file-signal", FILE_SIGNAL},
	{"file-sliders", FILE_SLIDERS},
	{"file-spreadsheet", FILE_SPREADSHEET},
	{"file-stack", FILE_STACK},
	{"file-symlink", FILE_SYMLINK},
	{"file-terminal", FILE_TERMINAL},
	{"file-text", FILE_TEXT},
	{"file-type", FILE_TYPE},
	{"file-type-2", FILE_TYPE_2},
	{"file-up", FILE_UP},
	{"file-user", FILE_USER},
	{"file-video-2", FILE_VIDEO_2},
	{"file-volume", FILE_VOLUME},
	{"file-x", FILE_X},
	{"file-x-2", FILE_X_2},
	{"files", FILES},
	{"film", FILM},
	{"filter", FILTER},
	{"filter-x", FILTER_X},
	{"fingerprint-pattern", FINGERPRINT_PATTERN},
	{"fire-extinguisher", FIRE_EXTINGUISHER},
	{"fish", FISH},
	{"fish-off", FISH_OFF},
	{"fish-symbol", FISH_SYMBOL},
	{"fishing-hook", FISHING_HOOK},
	{"fishing-rod", FISHING_ROD},
	{"flag", FLAG},
	{"flag-off", FLAG_OFF},
	{"flag-triangle-left", FLAG_TRIANGLE_LEFT},
	{"flag-triangle-right", FLAG_TRIANGLE_RIGHT},
	{"flame", FLAME},
	{"flame-kindling", FLAME_KINDLING},
	{"flashlight", FLASHLIGHT},
	{"flashlight-off", FLASHLIGHT_OFF},
	{"flask-conical", FLASK_CONICAL},
	{"flask-conical-off", FLASK_CONICAL_OFF},
	{"flask-round", FLASK_ROUND},
	{"flip-horizontal", FLIP_HORIZONTAL},
	{"flip-horizontal-2", FLIP_HORIZONTAL_2},
	{"flip-vertical", FLIP_VERTICAL},
	{"flip-vertical-2", FLIP_VERTICAL_2},
	{"flower", FLOWER},
	{"flower-2", FLOWER_2},
	{"focus", FOCUS},
	{"fold-horizontal", FOLD_HORIZONTAL},
	{"fold-vertical", FOLD_VERTICAL},
	{"folder", FOLDER},
	{"folder-archive", FOLDER_ARCHIVE},
	{"folder-bookmark", FOLDER_BOOKMARK},
	{"folder-check", FOLDER_CHECK},
	{"folder-clock", FOLDER_CLOCK},
	{"folder-closed", FOLDER_CLOSED},
	{"folder-code", FOLDER_CODE},
	{"folder-cog-2", FOLDER_COG_2},
	{"folder-dot", FOLDER_DOT},
	{"folder-down", FOLDER_DOWN},
	{"folder-edit", FOLDER_EDIT},
	{"folder-git", FOLDER_GIT},
	{"folder-git-2", FOLDER_GIT_2},
	{"folder-heart", FOLDER_HEART},
	{"folder-input", FOLDER_INPUT},
	{"folder-kanban", FOLDER_KANBAN},
	{"folder-key", FOLDER_KEY},
	{"folder-lock", FOLDER_LOCK},
	{"folder-minus", FOLDER_MINUS},
	{"folder-open", FOLDER_OPEN},
	{"folder-open-dot", FOLDER_OPEN_DOT},
	{"folder-output", FOLDER_OUTPUT},
	{"folder-plus", FOLDER_PLUS},
	{"folder-root", FOLDER_ROOT},
	{"folder-search", FOLDER_SEARCH},
	{"folder-search-2", FOLDER_SEARCH_2},
	{"folder-symlink", FOLDER_SYMLINK},
	{"folder-sync", FOLDER_SYNC},
	{"folder-tree", FOLDER_TREE},
	{"folder-up", FOLDER_UP},
	{"folder-x", FOLDER_X},
	{"folders", FOLDERS},
	{"footprints", FOOTPRINTS},
	{"fork-knife", FORK_KNIFE},
	{"fork-knife-crossed", FORK_KNIFE_CROSSED},
	{"forklift", FORKLIFT},
	{"form", FORM},
	{"form-input", FORM_INPUT},
	{"forward", FORWARD},
	{"frame", FRAME},
	{"fuel", FUEL},
	{"fullscreen", FULLSCREEN},
	{"function-square", FUNCTION_SQUARE},
	{"funnel-plus", FUNNEL_PLUS},
	{"galaxy", GALAXY},
	{"gallery-horizontal", GALLERY_HORIZONTAL},
	{"gallery-horizontal-end", GALLERY_HORIZONTAL_END},
	{"gallery-thumbnails", GALLERY_THUMBNAILS},
	{"gallery-vertical", GALLERY_VERTICAL},
	{"gallery-vertical-end", GALLERY_VERTICAL_END},
	{"gamepad", GAMEPAD},
	{"gamepad-2", GAMEPAD_2},
	{"gamepad-directional", GAMEPAD_DIRECTIONAL},
	{"gantt-chart-square", GANTT_CHART_SQUARE},
	{"gap-horizontal", GAP_HORIZONTAL},
	{"gap-vertical", GAP_VERTICAL},
	{"gauge", GAUGE},
	{"gavel", GAVEL},
	{"gem", GEM},
	{"georgian-lari", GEORGIAN_LARI},
	{"germ", GERM},
	{"germ-off", GERM_OFF},
	{"ghost", GHOST},
	{"gift", GIFT},
	{"git-branch", GIT_BRANCH},
	{"git-branch-minus", GIT_BRANCH_MINUS},
	{"git-branch-plus", GIT_BRANCH_PLUS},
	{"git-commit-horizontal", GIT_COMMIT_HORIZONTAL},
	{"git-commit-vertical", GIT_COMMIT_VERTICAL},
	{"git-compare", GIT_COMPARE},
	{"git-compare-arrows", GIT_COMPARE_ARROWS},
	{"git-fork", GIT_FORK},
	{"git-graph", GIT_GRAPH},
	{"git-merge", GIT_MERGE},
	{"git-merge-conflict", GIT_MERGE_CONFLICT},
	{"git-pull-request", GIT_PULL_REQUEST},
	{"git-pull-request-arrow", GIT_PULL_REQUEST_ARROW},
	{"git-pull-request-closed", GIT_PULL_REQUEST_CLOSED},
	{"git-pull-request-create", GIT_PULL_REQUEST_CREATE},
	{"git-pull-request-create-arrow", GIT_PULL_REQUEST_CREATE_ARROW},
	{"git-pull-request-draft", GIT_PULL_REQUEST_DRAFT},
	{"glass-water", GLASS_WATER},
	{"glasses", GLASSES},
	{"globe", GLOBE},
	{"globe-check", GLOBE_CHECK},
	{"globe-code", GLOBE_CODE},
	{"globe-lock", GLOBE_LOCK},
	{"globe-off", GLOBE_OFF},
	{"globe-x", GLOBE_X},
	{"goal", GOAL},
	{"gpu", GPU},
	{"grab", GRAB},
	{"graduation-cap", GRADUATION_CAP},
	{"grape", GRAPE},
	{"grid-2-x-2", GRID_2_X_2},
	{"grid-2-x-2-check", GRID_2_X_2_CHECK},
	{"grid-2-x-2-plus", GRID_2_X_2_PLUS},
	{"grid-2-x-2-x", GRID_2_X_2_X},
	{"grid-3-x-3", GRID_3_X_3},
	{"grid-3x2", GRID_3X2},
	{"grip", GRIP},
	{"grip-horizontal", GRIP_HORIZONTAL},
	{"grip-vertical", GRIP_VERTICAL},
	{"groceries", GROCERIES},
	{"group", GROUP},
	{"guitar", GUITAR},
	{"ham", HAM},
	{"hamburger", HAMBURGER},
	{"hammer", HAMMER},
	{"hand", HAND},
	{"hand-coins", HAND_COINS},
	{"hand-fist", HAND_FIST},
	{"hand-heart", HAND_HEART},
	{"hand-helping", HAND_HELPING},
	{"hand-metal", HAND_METAL},
	{"hand-platter", HAND_PLATTER},
	{"handbag", HANDBAG},
	{"handle-bottom-right", HANDLE_BOTTOM_RIGHT},
	{"handshake", HANDSHAKE},
	{"hard-drive", HARD_DRIVE},
	{"hard-drive-download", HARD_DRIVE_DOWNLOAD},
	{"hard-drive-upload", HARD_DRIVE_UPLOAD},
	{"hard-hat", HARD_HAT},
	{"hash", HASH},
	{"hat-glasses", HAT_GLASSES},
	{"haze", HAZE},
	{"hd", HD},
	{"hdmi-port", HDMI_PORT},
	{"heading", HEADING},
	{"heading-1", HEADING_1},
	{"heading-2", HEADING_2},
	{"heading-3", HEADING_3},
	{"heading-4", HEADING_4},
	{"heading-5", HEADING_5},
	{"heading-6", HEADING_6},
	{"headphone-off", HEADPHONE_OFF},
	{"headphones", HEADPHONES},
	{"headset", HEADSET},
	{"heart", HEART},
	{"heart-crack", HEART_CRACK},
	{"heart-handshake", HEART_HANDSHAKE},
	{"heart-minus", HEART_MINUS},
	{"heart-off", HEART_OFF},
	{"heart-plus", HEART_PLUS},
	{"heart-pulse", HEART_PULSE},
	{"heart-x", HEART_X},
	{"heater", HEATER},
	{"helicopter", HELICOPTER},
	{"hexagon", HEXAGON},
	{"highlighter", HIGHLIGHTER},
	{"hiking-stick", HIKING_STICK},
	{"history", HISTORY},
	{"home", HOME},
	{"hop", HOP},
	{"hop-off", HOP_OFF},
	{"hospital", HOSPITAL},
	{"hotel", HOTEL},
	{"hourglass", HOURGLASS},
	{"hourglass-cog", HOURGLASS_COG},
	{"house-cog", HOUSE_COG},
	{"house-heart", HOUSE_HEART},
	{"house-plug", HOUSE_PLUG},
	{"house-plus", HOUSE_PLUS},
	{"house-wifi", HOUSE_WIFI},
	{"houses", HOUSES},
	{"ice-cream-2", ICE_CREAM_2},
	{"ice-cream-cone", ICE_CREAM_CONE},
	{"id-card", ID_CARD},
	{"id-card-lanyard", ID_CARD_LANYARD},
	{"image", IMAGE},
	{"image-down", IMAGE_DOWN},
	{"image-minus", IMAGE_MINUS},
	{"image-off", IMAGE_OFF},
	{"image-play", IMAGE_PLAY},
	{"image-plus", IMAGE_PLUS},
	{"image-up", IMAGE_UP},
	{"image-upscale", IMAGE_UPSCALE},
	{"images", IMAGES},
	{"import", IMPORT},
	{"inbox", INBOX},
	{"indent-decrease", INDENT_DECREASE},
	{"indent-increase", INDENT_INCREASE},
	{"indian-rupee", INDIAN_RUPEE},
	{"infinity", INFINITY},
	{"info", INFO},
	{"inspect", INSPECT},
	{"inspection-panel", INSPECTION_PANEL},
	{"italic", ITALIC},
	{"iteration-ccw", ITERATION_CCW},
	{"iteration-cw", ITERATION_CW},
	{"iv-bag", IV_BAG},
	{"japanese-yen", JAPANESE_YEN},
	{"joystick", JOYSTICK},
	{"kanban", KANBAN},
	{"kanban-square", KANBAN_SQUARE},
	{"kanban-square-dashed", KANBAN_SQUARE_DASHED},
	{"kayak", KAYAK},
	{"kazakh-tenge", KAZAKH_TENGE},
	{"key", KEY},
	{"key-round", KEY_ROUND},
	{"key-square", KEY_SQUARE},
	{"keyboard", KEYBOARD},
	{"keyboard-music", KEYBOARD_MUSIC},
	{"keyboard-off", KEYBOARD_OFF},
	{"lambda", LAMBDA},
	{"lamp", LAMP},
	{"lamp-ceiling", LAMP_CEILING},
	{"lamp-desk", LAMP_DESK},
	{"lamp-floor", LAMP_FLOOR},
	{"lamp-wall-down", LAMP_WALL_DOWN},
	{"lamp-wall-up", LAMP_WALL_UP},
	{"land-plot", LAND_PLOT},
	{"landmark", LANDMARK},
	{"languages", LANGUAGES},
	{"laptop", LAPTOP},
	{"laptop-2", LAPTOP_2},
	{"laptop-minimal-check", LAPTOP_MINIMAL_CHECK},
	{"lasso", LASSO},
	{"lasso-select", LASSO_SELECT},
	{"layer-arrow-down", LAYER_ARROW_DOWN},
	{"layer-arrow-up", LAYER_ARROW_UP},
	{"layers-2", LAYERS_2},
	{"layers-3", LAYERS_3},
	{"layers-arrow-down", LAYERS_ARROW_DOWN},
	{"layers-arrow-up", LAYERS_ARROW_UP},
	{"layers-minus", LAYERS_MINUS},
	{"layers-plus", LAYERS_PLUS},
	{"layout", LAYOUT},
	{"layout-arrow-down", LAYOUT_ARROW_DOWN},
	{"layout-arrow-right", LAYOUT_ARROW_RIGHT},
	{"layout-dashboard", LAYOUT_DASHBOARD},
	{"layout-freeform", LAYOUT_FREEFORM},
	{"layout-grid", LAYOUT_GRID},
	{"layout-grid-circles", LAYOUT_GRID_CIRCLES},
	{"layout-list", LAYOUT_LIST},
	{"layout-panel-left", LAYOUT_PANEL_LEFT},
	{"layout-panel-top", LAYOUT_PANEL_TOP},
	{"layout-template", LAYOUT_TEMPLATE},
	{"leaf", LEAF},
	{"leafy-green", LEAFY_GREEN},
	{"lectern", LECTERN},
	{"lens", LENS},
	{"lens-concave", LENS_CONCAVE},
	{"lens-convex", LENS_CONVEX},
	{"letter-text", LETTER_TEXT},
	{"letters", LETTERS},
	{"library", LIBRARY},
	{"library-big", LIBRARY_BIG},
	{"library-square", LIBRARY_SQUARE},
	{"life-buoy", LIFE_BUOY},
	{"ligature", LIGATURE},
	{"lightbulb", LIGHTBULB},
	{"lightbulb-off", LIGHTBULB_OFF},
	{"lighthouse", LIGHTHOUSE},
	{"line-dot-bottom-vertical", LINE_DOT_BOTTOM_VERTICAL},
	{"line-dot-left-horizontal", LINE_DOT_LEFT_HORIZONTAL},
	{"line-dot-right-horizontal", LINE_DOT_RIGHT_HORIZONTAL},
	{"line-dot-top-vertical", LINE_DOT_TOP_VERTICAL},
	{"line-squiggle", LINE_SQUIGGLE},
	{"line-style", LINE_STYLE},
	{"link", LINK},
	{"link-2", LINK_2},
	{"link-2-off", LINK_2_OFF},
	{"list", LIST},
	{"list-check", LIST_CHECK},
	{"list-checks", LIST_CHECKS},
	{"list-chevrons-down-up", LIST_CHEVRONS_DOWN_UP},
	{"list-chevrons-up-down", LIST_CHEVRONS_UP_DOWN},
	{"list-clock", LIST_CLOCK},
	{"list-collapse", LIST_COLLAPSE},
	{"list-end", LIST_END},
	{"list-filter", LIST_FILTER},
	{"list-filter-plus", LIST_FILTER_PLUS},
	{"list-minus", LIST_MINUS},
	{"list-music", LIST_MUSIC},
	{"list-ordered", LIST_ORDERED},
	{"list-plus", LIST_PLUS},
	{"list-restart", LIST_RESTART},
	{"list-sort-ascending", LIST_SORT_ASCENDING},
	{"list-sort-descending", LIST_SORT_DESCENDING},
	{"list-start", LIST_START},
	{"list-todo", LIST_TODO},
	{"list-tree", LIST_TREE},
	{"list-video", LIST_VIDEO},
	{"list-x", LIST_X},
	{"loader", LOADER},
	{"loader-2", LOADER_2},
	{"loader-pinwheel", LOADER_PINWHEEL},
	{"locate", LOCATE},
	{"locate-fixed", LOCATE_FIXED},
	{"locate-off", LOCATE_OFF},
	{"location-edit", LOCATION_EDIT},
	{"lock", LOCK},
	{"lock-keyhole", LOCK_KEYHOLE},
	{"lock-keyhole-open", LOCK_KEYHOLE_OPEN},
	{"lock-open", LOCK_OPEN},
	{"log-in", LOG_IN},
	{"log-out", LOG_OUT},
	{"logs", LOGS},
	{"lollipop", LOLLIPOP},
	{"luggage", LUGGAGE},
	{"m-square", M_SQUARE},
	{"magnet", MAGNET},
	{"mail", MAIL},
	{"mail-badge", MAIL_BADGE},
	{"mail-check", MAIL_CHECK},
	{"mail-clock", MAIL_CLOCK},
	{"mail-dot", MAIL_DOT},
	{"mail-minus", MAIL_MINUS},
	{"mail-open", MAIL_OPEN},
	{"mail-pen", MAIL_PEN},
	{"mail-plus", MAIL_PLUS},
	{"mail-question-mark", MAIL_QUESTION_MARK},
	{"mail-search", MAIL_SEARCH},
	{"mail-warning", MAIL_WARNING},
	{"mail-x", MAIL_X},
	{"mailbox", MAILBOX},
	{"mails", MAILS},
	{"map", MAP},
	{"map-minus", MAP_MINUS},
	{"map-pin", MAP_PIN},
	{"map-pin-check", MAP_PIN_CHECK},
	{"map-pin-check-inside", MAP_PIN_CHECK_INSIDE},
	{"map-pin-house", MAP_PIN_HOUSE},
	{"map-pin-minus", MAP_PIN_MINUS},
	{"map-pin-minus-inside", MAP_PIN_MINUS_INSIDE},
	{"map-pin-off", MAP_PIN_OFF},
	{"map-pin-plus", MAP_PIN_PLUS},
	{"map-pin-plus-inside", MAP_PIN_PLUS_INSIDE},
	{"map-pin-search", MAP_PIN_SEARCH},
	{"map-pin-x", MAP_PIN_X},
	{"map-pin-x-inside", MAP_PIN_X_INSIDE},
	{"map-pinned", MAP_PINNED},
	{"map-plus", MAP_PLUS},
	{"mars", MARS},
	{"mars-stroke", MARS_STROKE},
	{"martini", MARTINI},
	{"maximize", MAXIMIZE},
	{"maximize-2", MAXIMIZE_2},
	{"medal", MEDAL},
	{"megaphone", MEGAPHONE},
	{"megaphone-off", MEGAPHONE_OFF},
	{"memory-stick", MEMORY_STICK},
	{"menu", MENU},
	{"menu-square", MENU_SQUARE},
	{"merge", MERGE},
	{"message-circle", MESSAGE_CIRCLE},
	{"message-circle-check", MESSAGE_CIRCLE_CHECK},
	{"message-circle-code", MESSAGE_CIRCLE_CODE},
	{"message-circle-dashed", MESSAGE_CIRCLE_DASHED},
	{"message-circle-dashed-check", MESSAGE_CIRCLE_DASHED_CHECK},
	{"message-circle-heart", MESSAGE_CIRCLE_HEART},
	{"message-circle-more", MESSAGE_CIRCLE_MORE},
	{"message-circle-off", MESSAGE_CIRCLE_OFF},
	{"message-circle-plus", MESSAGE_CIRCLE_PLUS},
	{"message-circle-question-mark", MESSAGE_CIRCLE_QUESTION_MARK},
	{"message-circle-reply", MESSAGE_CIRCLE_REPLY},
	{"message-circle-warning", MESSAGE_CIRCLE_WARNING},
	{"message-circle-x", MESSAGE_CIRCLE_X},
	{"message-square", MESSAGE_SQUARE},
	{"message-square-check", MESSAGE_SQUARE_CHECK},
	{"message-square-code", MESSAGE_SQUARE_CODE},
	{"message-square-dashed", MESSAGE_SQUARE_DASHED},
	{"message-square-diff", MESSAGE_SQUARE_DIFF},
	{"message-square-dot", MESSAGE_SQUARE_DOT},
	{"message-square-heart", MESSAGE_SQUARE_HEART},
	{"message-square-lock", MESSAGE_SQUARE_LOCK},
	{"message-square-more", MESSAGE_SQUARE_MORE},
	{"message-square-off", MESSAGE_SQUARE_OFF},
	{"message-square-plus", MESSAGE_SQUARE_PLUS},
	{"message-square-quote", MESSAGE_SQUARE_QUOTE},
	{"message-square-reply", MESSAGE_SQUARE_REPLY},
	{"message-square-share", MESSAGE_SQUARE_SHARE},
	{"message-square-text", MESSAGE_SQUARE_TEXT},
	{"message-square-warning", MESSAGE_SQUARE_WARNING},
	{"message-square-x", MESSAGE_SQUARE_X},
	{"messages-circle", MESSAGES_CIRCLE},
	{"messages-square", MESSAGES_SQUARE},
	{"metronome", METRONOME},
	{"mic", MIC},
	{"mic-2", MIC_2},
	{"mic-audio-lines", MIC_AUDIO_LINES},
	{"mic-off", MIC_OFF},
	{"mic-signal", MIC_SIGNAL},
	{"microchip", MICROCHIP},
	{"microscope", MICROSCOPE},
	{"microwave", MICROWAVE},
	{"midi-port", MIDI_PORT},
	{"milestone", MILESTONE},
	{"milk", MILK},
	{"milk-off", MILK_OFF},
	{"minimize", MINIMIZE},
	{"minimize-2", MINIMIZE_2},
	{"minus", MINUS},
	{"minus-square", MINUS_SQUARE},
	{"mirror-rectangular", MIRROR_RECTANGULAR},
	{"mirror-round", MIRROR_ROUND},
	{"monitor", MONITOR},
	{"monitor-check", MONITOR_CHECK},
	{"monitor-cloud", MONITOR_CLOUD},
	{"monitor-cog", MONITOR_COG},
	{"monitor-dot", MONITOR_DOT},
	{"monitor-down", MONITOR_DOWN},
	{"monitor-off", MONITOR_OFF},
	{"monitor-pause", MONITOR_PAUSE},
	{"monitor-pc", MONITOR_PC},
	{"monitor-play", MONITOR_PLAY},
	{"monitor-smartphone", MONITOR_SMARTPHONE},
	{"monitor-speaker", MONITOR_SPEAKER},
	{"monitor-stop", MONITOR_STOP},
	{"monitor-up", MONITOR_UP},
	{"monitor-x", MONITOR_X},
	{"moon", MOON},
	{"moon-star", MOON_STAR},
	{"mop", MOP},
	{"mop-sparkles", MOP_SPARKLES},
	{"mosque", MOSQUE},
	{"motorbike", MOTORBIKE},
	{"mountain", MOUNTAIN},
	{"mountain-snow", MOUNTAIN_SNOW},
	{"mouse", MOUSE},
	{"mouse-left", MOUSE_LEFT},
	{"mouse-off", MOUSE_OFF},
	{"mouse-pointer", MOUSE_POINTER},
	{"mouse-pointer-2", MOUSE_POINTER_2},
	{"mouse-pointer-2-off", MOUSE_POINTER_2_OFF},
	{"mouse-pointer-ban", MOUSE_POINTER_BAN},
	{"mouse-pointer-click", MOUSE_POINTER_CLICK},
	{"mouse-pointer-square-dashed", MOUSE_POINTER_SQUARE_DASHED},
	{"mouse-right", MOUSE_RIGHT},
	{"mouth", MOUTH},
	{"mouth-off", MOUTH_OFF},
	{"move", MOVE},
	{"move-3-d", MOVE_3_D},
	{"move-diagonal", MOVE_DIAGONAL},
	{"move-diagonal-2", MOVE_DIAGONAL_2},
	{"move-down", MOVE_DOWN},
	{"move-down-left", MOVE_DOWN_LEFT},
	{"move-down-right", MOVE_DOWN_RIGHT},
	{"move-horizontal", MOVE_HORIZONTAL},
	{"move-left", MOVE_LEFT},
	{"move-right", MOVE_RIGHT},
	{"move-up", MOVE_UP},
	{"move-up-left", MOVE_UP_LEFT},
	{"move-up-right", MOVE_UP_RIGHT},
	{"move-vertical", MOVE_VERTICAL},
	{"music", MUSIC},
	{"music-2", MUSIC_2},
	{"music-3", MUSIC_3},
	{"music-4", MUSIC_4},
	{"navigation", NAVIGATION},
	{"navigation-2", NAVIGATION_2},
	{"navigation-2-off", NAVIGATION_2_OFF},
	{"navigation-off", NAVIGATION_OFF},
	{"nepali-rupee", NEPALI_RUPEE},
	{"network", NETWORK},
	{"newspaper", NEWSPAPER},
	{"nfc", NFC},
	{"non-binary", NON_BINARY},
	{"notebook", NOTEBOOK},
	{"notebook-dot", NOTEBOOK_DOT},
	{"notebook-pen", NOTEBOOK_PEN},
	{"notebook-tabs", NOTEBOOK_TABS},
	{"notebook-text", NOTEBOOK_TEXT},
	{"notepad-text", NOTEPAD_TEXT},
	{"notepad-text-dashed", NOTEPAD_TEXT_DASHED},
	{"nut", NUT},
	{"nut-off", NUT_OFF},
	{"octagon", OCTAGON},
	{"octagon-minus", OCTAGON_MINUS},
	{"octagon-pause", OCTAGON_PAUSE},
	{"octagon-x", OCTAGON_X},
	{"omega", OMEGA},
	{"option", OPTION},
	{"orbit", ORBIT},
	{"origami", ORIGAMI},
	{"package", PACKAGE},
	{"package-2", PACKAGE_2},
	{"package-check", PACKAGE_CHECK},
	{"package-minus", PACKAGE_MINUS},
	{"package-open", PACKAGE_OPEN},
	{"package-plus", PACKAGE_PLUS},
	{"package-search", PACKAGE_SEARCH},
	{"package-x", PACKAGE_X},
	{"paint-bucket", PAINT_BUCKET},
	{"paint-roller", PAINT_ROLLER},
	{"paintbrush", PAINTBRUSH},
	{"paintbrush-2", PAINTBRUSH_2},
	{"palette", PALETTE},
	{"palmtree", PALMTREE},
	{"panda", PANDA},
	{"panel-bottom", PANEL_BOTTOM},
	{"panel-bottom-close", PANEL_BOTTOM_CLOSE},
	{"panel-bottom-dashed", PANEL_BOTTOM_DASHED},
	{"panel-bottom-open", PANEL_BOTTOM_OPEN},
	{"panel-left", PANEL_LEFT},
	{"panel-left-close", PANEL_LEFT_CLOSE},
	{"panel-left-dashed", PANEL_LEFT_DASHED},
	{"panel-left-open", PANEL_LEFT_OPEN},
	{"panel-left-right-dashed", PANEL_LEFT_RIGHT_DASHED},
	{"panel-right", PANEL_RIGHT},
	{"panel-right-close", PANEL_RIGHT_CLOSE},
	{"panel-right-dashed", PANEL_RIGHT_DASHED},
	{"panel-right-open", PANEL_RIGHT_OPEN},
	{"panel-top", PANEL_TOP},
	{"panel-top-bottom-dashed", PANEL_TOP_BOTTOM_DASHED},
	{"panel-top-close", PANEL_TOP_CLOSE},
	{"panel-top-dashed", PANEL_TOP_DASHED},
	{"panel-top-open", PANEL_TOP_OPEN},
	{"panels-left-bottom", PANELS_LEFT_BOTTOM},
	{"panels-right-bottom", PANELS_RIGHT_BOTTOM},
	{"panels-top-bottom", PANELS_TOP_BOTTOM},
	{"paper-bag", PAPER_BAG},
	{"paperclip", PAPERCLIP},
	{"parasol", PARASOL},
	{"parentheses", PARENTHESES},
	{"park", PARK},
	{"parking-meter", PARKING_METER},
	{"parking-square", PARKING_SQUARE},
	{"parking-square-off", PARKING_SQUARE_OFF},
	{"party-popper", PARTY_POPPER},
	{"pause", PAUSE},
	{"paw-print", PAW_PRINT},
	{"pc-case", PC_CASE},
	{"pen-off", PEN_OFF},
	{"pen-tool", PEN_TOOL},
	{"pencil", PENCIL},
	{"pencil-line", PENCIL_LINE},
	{"pencil-off", PENCIL_OFF},
	{"pencil-ruler", PENCIL_RULER},
	{"pencil-sparkles", PENCIL_SPARKLES},
	{"pentagon", PENTAGON},
	{"percent", PERCENT},
	{"percent-square", PERCENT_SQUARE},
	{"person-standing", PERSON_STANDING},
	{"phi", PHI},
	{"philippine-peso", PHILIPPINE_PESO},
	{"phone", PHONE},
	{"phone-call", PHONE_CALL},
	{"phone-forwarded", PHONE_FORWARDED},
	{"phone-incoming", PHONE_INCOMING},
	{"phone-log", PHONE_LOG},
	{"phone-missed", PHONE_MISSED},
	{"phone-off", PHONE_OFF},
	{"phone-outgoing", PHONE_OUTGOING},
	{"pi", PI},
	{"pi-square", PI_SQUARE},
	{"piano", PIANO},
	{"pickaxe", PICKAXE},
	{"picture-in-picture", PICTURE_IN_PICTURE},
	{"picture-in-picture-2", PICTURE_IN_PICTURE_2},
	{"piggy-bank", PIGGY_BANK},
	{"pilcrow", PILCROW},
	{"pilcrow-left", PILCROW_LEFT},
	{"pilcrow-right", PILCROW_RIGHT},
	{"pilcrow-square", PILCROW_SQUARE},
	{"pill", PILL},
	{"pill-bottle", PILL_BOTTLE},
	{"pin", PIN},
	{"pin-off", PIN_OFF},
	{"pipette", PIPETTE},
	{"pizza", PIZZA},
	{"plane", PLANE},
	{"plane-landing", PLANE_LANDING},
	{"plane-takeoff", PLANE_TAKEOFF},
	{"plant-pot", PLANT_POT},
	{"play", PLAY},
	{"play-off", PLAY_OFF},
	{"play-square", PLAY_SQUARE},
	{"playing-card", PLAYING_CARD},
	{"playing-cards", PLAYING_CARDS},
	{"playing-cards-fan", PLAYING_CARDS_FAN},
	{"plug", PLUG},
	{"plug-2", PLUG_2},
	{"plug-zap-2", PLUG_ZAP_2},
	{"plus", PLUS},
	{"plus-square", PLUS_SQUARE},
	{"pocket-knife", POCKET_KNIFE},
	{"podium", PODIUM},
	{"pointer", POINTER},
	{"pointer-off", POINTER_OFF},
	{"popcorn", POPCORN},
	{"popsicle", POPSICLE},
	{"pound-sterling", POUND_STERLING},
	{"power", POWER},
	{"power-off", POWER_OFF},
	{"power-square", POWER_SQUARE},
	{"presentation", PRESENTATION},
	{"printer", PRINTER},
	{"printer-3d", PRINTER_3D},
	{"printer-check", PRINTER_CHECK},
	{"printer-x", PRINTER_X},
	{"projector", PROJECTOR},
	{"proportions", PROPORTIONS},
	{"puzzle", PUZZLE},
	{"pyramid", PYRAMID},
	{"qr-code", QR_CODE},
	{"quote", QUOTE},
	{"rabbit", RABBIT},
	{"radar", RADAR},
	{"radiation", RADIATION},
	{"radical", RADICAL},
	{"radio", RADIO},
	{"radio-off", RADIO_OFF},
	{"radio-receiver", RADIO_RECEIVER},
	{"radio-tower", RADIO_TOWER},
	{"radius", RADIUS},
	{"rainbow", RAINBOW},
	{"rat", RAT},
	{"ratio", RATIO},
	{"receipt", RECEIPT},
	{"receipt-cent", RECEIPT_CENT},
	{"receipt-euro", RECEIPT_EURO},
	{"receipt-indian-rupee", RECEIPT_INDIAN_RUPEE},
	{"receipt-japanese-yen", RECEIPT_JAPANESE_YEN},
	{"receipt-pound-sterling", RECEIPT_POUND_STERLING},
	{"receipt-russian-ruble", RECEIPT_RUSSIAN_RUBLE},
	{"receipt-swiss-franc", RECEIPT_SWISS_FRANC},
	{"receipt-text", RECEIPT_TEXT},
	{"receipt-turkish-lira", RECEIPT_TURKISH_LIRA},
	{"rectangle-circle", RECTANGLE_CIRCLE},
	{"rectangle-goggles", RECTANGLE_GOGGLES},
	{"rectangle-horizontal", RECTANGLE_HORIZONTAL},
	{"rectangle-vertical", RECTANGLE_VERTICAL},
	{"recycle", RECYCLE},
	{"redo", REDO},
	{"redo-2", REDO_2},
	{"redo-dot", REDO_DOT},
	{"refresh-ccw", REFRESH_CCW},
	{"refresh-ccw-dot", REFRESH_CCW_DOT},
	{"refresh-cw", REFRESH_CW},
	{"refresh-cw-off", REFRESH_CW_OFF},
	{"refrigerator", REFRIGERATOR},
	{"regex", REGEX},
	{"remove-formatting", REMOVE_FORMATTING},
	{"repeat", REPEAT},
	{"repeat-1", REPEAT_1},
	{"repeat-2", REPEAT_2},
	{"repeat-off", REPEAT_OFF},
	{"replace", REPLACE},
	{"replace-all", REPLACE_ALL},
	{"reply", REPLY},
	{"reply-all", REPLY_ALL},
	{"rewind", REWIND},
	{"ribbon", RIBBON},
	{"road", ROAD},
	{"robot-arm", ROBOT_ARM},
	{"robot-vacuum", ROBOT_VACUUM},
	{"rocket", ROCKET},
	{"rocking-chair", ROCKING_CHAIR},
	{"roller-coaster", ROLLER_COASTER},
	{"rose", ROSE},
	{"rotate-3-d", ROTATE_3_D},
	{"rotate-ccw", ROTATE_CCW},
	{"rotate-ccw-key", ROTATE_CCW_KEY},
	{"rotate-ccw-square", ROTATE_CCW_SQUARE},
	{"rotate-cw", ROTATE_CW},
	{"rotate-cw-clock", ROTATE_CW_CLOCK},
	{"rotate-cw-fading-clock", ROTATE_CW_FADING_CLOCK},
	{"rotate-cw-square", ROTATE_CW_SQUARE},
	{"route", ROUTE},
	{"route-off", ROUTE_OFF},
	{"router", ROUTER},
	{"rows-2", ROWS_2},
	{"rows-4", ROWS_4},
	{"rss", RSS},
	{"rugby-ball", RUGBY_BALL},
	{"ruler", RULER},
	{"ruler-dimension-line", RULER_DIMENSION_LINE},
	{"russian-ruble", RUSSIAN_RUBLE},
	{"sailboat", SAILBOAT},
	{"salad", SALAD},
	{"sandwich", SANDWICH},
	{"satellite", SATELLITE},
	{"satellite-dish", SATELLITE_DISH},
	{"saudi-riyal", SAUDI_RIYAL},
	{"save", SAVE},
	{"save-all", SAVE_ALL},
	{"save-check", SAVE_CHECK},
	{"save-off", SAVE_OFF},
	{"save-pen", SAVE_PEN},
	{"save-plus", SAVE_PLUS},
	{"scale", SCALE},
	{"scale-3-d", SCALE_3_D},
	{"scaling", SCALING},
	{"scan", SCAN},
	{"scan-barcode", SCAN_BARCODE},
	{"scan-box", SCAN_BOX},
	{"scan-eye", SCAN_EYE},
	{"scan-face", SCAN_FACE},
	{"scan-heart", SCAN_HEART},
	{"scan-line", SCAN_LINE},
	{"scan-qr-code", SCAN_QR_CODE},
	{"scan-search", SCAN_SEARCH},
	{"scan-square", SCAN_SQUARE},
	{"scan-text", SCAN_TEXT},
	{"school", SCHOOL},
	{"school-2", SCHOOL_2},
	{"scissors", SCISSORS},
	{"scissors-line-dashed", SCISSORS_LINE_DASHED},
	{"scissors-square", SCISSORS_SQUARE},
	{"scissors-square-dashed-bottom", SCISSORS_SQUARE_DASHED_BOTTOM},
	{"scooter", SCOOTER},
	{"scratch-blocks", SCRATCH_BLOCKS},
	{"screen-share", SCREEN_SHARE},
	{"screen-share-off", SCREEN_SHARE_OFF},
	{"screw", SCREW},
	{"scroll", SCROLL},
	{"scroll-text", SCROLL_TEXT},
	{"search", SEARCH},
	{"search-alert", SEARCH_ALERT},
	{"search-check", SEARCH_CHECK},
	{"search-code", SEARCH_CODE},
	{"search-slash", SEARCH_SLASH},
	{"search-x", SEARCH_X},
	{"section", SECTION},
	{"send", SEND},
	{"send-horizonal", SEND_HORIZONAL},
	{"send-to-back", SEND_TO_BACK},
	{"separator-horizontal", SEPARATOR_HORIZONTAL},
	{"separator-vertical", SEPARATOR_VERTICAL},
	{"server", SERVER},
	{"server-cog", SERVER_COG},
	{"server-crash", SERVER_CRASH},
	{"server-off", SERVER_OFF},
	{"server-plus", SERVER_PLUS},
	{"settings", SETTINGS},
	{"settings-2", SETTINGS_2},
	{"shapes", SHAPES},
	{"share", SHARE},
	{"share-2", SHARE_2},
	{"sheet", SHEET},
	{"shell", SHELL},
	{"shelving-unit", SHELVING_UNIT},
	{"shield", SHIELD},
	{"shield-alert", SHIELD_ALERT},
	{"shield-ban", SHIELD_BAN},
	{"shield-check", SHIELD_CHECK},
	{"shield-close", SHIELD_CLOSE},
	{"shield-cog", SHIELD_COG},
	{"shield-cog-corner", SHIELD_COG_CORNER},
	{"shield-ellipsis", SHIELD_ELLIPSIS},
	{"shield-half", SHIELD_HALF},
	{"shield-house", SHIELD_HOUSE},
	{"shield-keyhole", SHIELD_KEYHOLE},
	{"shield-lock", SHIELD_LOCK},
	{"shield-minus", SHIELD_MINUS},
	{"shield-off", SHIELD_OFF},
	{"shield-plus", SHIELD_PLUS},
	{"shield-question-mark", SHIELD_QUESTION_MARK},
	{"shield-user", SHIELD_USER},
	{"ship", SHIP},
	{"ship-cargo", SHIP_CARGO},
	{"ship-wheel", SHIP_WHEEL},
	{"shirt", SHIRT},
	{"shopping-bag", SHOPPING_BAG},
	{"shopping-basket", SHOPPING_BASKET},
	{"shopping-cart", SHOPPING_CART},
	{"shopping-cart-minus", SHOPPING_CART_MINUS},
	{"shopping-cart-plus", SHOPPING_CART_PLUS},
	{"shovel", SHOVEL},
	{"shower-head", SHOWER_HEAD},
	{"shredder", SHREDDER},
	{"shrimp", SHRIMP},
	{"shrimp-off", SHRIMP_OFF},
	{"shrink", SHRINK},
	{"shrub", SHRUB},
	{"shuffle", SHUFFLE},
	{"sigma", SIGMA},
	{"sigma-square", SIGMA_SQUARE},
	{"signal", SIGNAL},
	{"signal-high", SIGNAL_HIGH},
	{"signal-low", SIGNAL_LOW},
	{"signal-medium", SIGNAL_MEDIUM},
	{"signal-zero", SIGNAL_ZERO},
	{"signature", SIGNATURE},
	{"signpost", SIGNPOST},
	{"signpost-big", SIGNPOST_BIG},
	{"siren", SIREN},
	{"skip-back", SKIP_BACK},
	{"skip-forward", SKIP_FORWARD},
	{"skull", SKULL},
	{"slash", SLASH},
	{"slash-square", SLASH_SQUARE},
	{"slice", SLICE},
	{"sliders-horizontal", SLIDERS_HORIZONTAL},
	{"sliders-vertical", SLIDERS_VERTICAL},
	{"smartphone", SMARTPHONE},
	{"smartphone-charging", SMARTPHONE_CHARGING},
	{"smartphone-nfc", SMARTPHONE_NFC},
	{"snail", SNAIL},
	{"snowflake", SNOWFLAKE},
	{"soap-dispenser-droplet", SOAP_DISPENSER_DROPLET},
	{"sofa", SOFA},
	{"solar-panel", SOLAR_PANEL},
	{"soup", SOUP},
	{"space", SPACE},
	{"spade", SPADE},
	{"sparkle", SPARKLE},
	{"sparkles", SPARKLES},
	{"speaker", SPEAKER},
	{"speech", SPEECH},
	{"spell-check", SPELL_CHECK},
	{"spell-check-2", SPELL_CHECK_2},
	{"spline", SPLINE},
	{"spline-pointer", SPLINE_POINTER},
	{"split", SPLIT},
	{"split-square-horizontal", SPLIT_SQUARE_HORIZONTAL},
	{"split-square-vertical", SPLIT_SQUARE_VERTICAL},
	{"spool", SPOOL},
	{"sport-shoe", SPORT_SHOE},
	{"spotlight", SPOTLIGHT},
	{"spray-can", SPRAY_CAN},
	{"sprout", SPROUT},
	{"square", SQUARE},
	{"square-arrow-right-enter", SQUARE_ARROW_RIGHT_ENTER},
	{"square-arrow-right-exit", SQUARE_ARROW_RIGHT_EXIT},
	{"square-dashed-bottom", SQUARE_DASHED_BOTTOM},
	{"square-dashed-bottom-code", SQUARE_DASHED_BOTTOM_CODE},
	{"square-dashed-plus", SQUARE_DASHED_PLUS},
	{"square-dashed-text", SQUARE_DASHED_TEXT},
	{"square-dashed-top-solid", SQUARE_DASHED_TOP_SOLID},
	{"square-dashed-x", SQUARE_DASHED_X},
	{"square-dashed-x-corner", SQUARE_DASHED_X_CORNER},
	{"square-dimensions", SQUARE_DIMENSIONS},
	{"square-exclamation-point", SQUARE_EXCLAMATION_POINT},
	{"square-off", SQUARE_OFF},
	{"square-pause", SQUARE_PAUSE},
	{"square-radical", SQUARE_RADICAL},
	{"square-round-corner", SQUARE_ROUND_CORNER},
	{"square-sparkles", SQUARE_SPARKLES},
	{"square-square", SQUARE_SQUARE},
	{"square-stack", SQUARE_STACK},
	{"square-star", SQUARE_STAR},
	{"square-stop", SQUARE_STOP},
	{"square-terminal", SQUARE_TERMINAL},
	{"square-text", SQUARE_TEXT},
	{"square-user", SQUARE_USER},
	{"square-user-round", SQUARE_USER_ROUND},
	{"square-x", SQUARE_X},
	{"squares-exclude", SQUARES_EXCLUDE},
	{"squares-intersect", SQUARES_INTERSECT},
	{"squares-subtract", SQUARES_SUBTRACT},
	{"squares-unite", SQUARES_UNITE},
	{"squircle", SQUIRCLE},
	{"squircle-dashed", SQUIRCLE_DASHED},
	{"squirrel", SQUIRREL},
	{"stamp", STAMP},
	{"star", STAR},
	{"star-check", STAR_CHECK},
	{"star-half", STAR_HALF},
	{"star-minus", STAR_MINUS},
	{"star-off", STAR_OFF},
	{"star-plus", STAR_PLUS},
	{"star-x", STAR_X},
	{"step-back", STEP_BACK},
	{"step-forward", STEP_FORWARD},
	{"stethoscope", STETHOSCOPE},
	{"sticker", STICKER},
	{"sticky-note", STICKY_NOTE},
	{"sticky-note-check", STICKY_NOTE_CHECK},
	{"sticky-note-minus", STICKY_NOTE_MINUS},
	{"sticky-note-off", STICKY_NOTE_OFF},
	{"sticky-note-plus", STICKY_NOTE_PLUS},
	{"sticky-note-x", STICKY_NOTE_X},
	{"sticky-notes", STICKY_NOTES},
	{"stone", STONE},
	{"store", STORE},
	{"stretch-horizontal", STRETCH_HORIZONTAL},
	{"stretch-vertical", STRETCH_VERTICAL},
	{"strikethrough", STRIKETHROUGH},
	{"subscript", SUBSCRIPT},
	{"summary", SUMMARY},
	{"sun", SUN},
	{"sun-dim", SUN_DIM},
	{"sun-medium", SUN_MEDIUM},
	{"sun-moon", SUN_MOON},
	{"sun-snow", SUN_SNOW},
	{"sunrise", SUNRISE},
	{"sunset", SUNSET},
	{"superscript", SUPERSCRIPT},
	{"swatch-book", SWATCH_BOOK},
	{"swiss-franc", SWISS_FRANC},
	{"switch-camera", SWITCH_CAMERA},
	{"sword", SWORD},
	{"swords", SWORDS},
	{"syringe", SYRINGE},
	{"table", TABLE},
	{"table-2", TABLE_2},
	{"table-cells-merge", TABLE_CELLS_MERGE},
	{"table-cells-split", TABLE_CELLS_SPLIT},
	{"table-columns-split", TABLE_COLUMNS_SPLIT},
	{"table-of-contents", TABLE_OF_CONTENTS},
	{"table-properties", TABLE_PROPERTIES},
	{"table-rows-split", TABLE_ROWS_SPLIT},
	{"tablet", TABLET},
	{"tablet-smartphone", TABLET_SMARTPHONE},
	{"tablets", TABLETS},
	{"tag", TAG},
	{"tag-plus", TAG_PLUS},
	{"tag-x", TAG_X},
	{"tags", TAGS},
	{"tally-1", TALLY_1},
	{"tally-2", TALLY_2},
	{"tally-3", TALLY_3},
	{"tally-4", TALLY_4},
	{"tally-5", TALLY_5},
	{"tangent", TANGENT},
	{"target", TARGET},
	{"telescope", TELESCOPE},
	{"tent", TENT},
	{"tent-tree", TENT_TREE},
	{"terminal", TERMINAL},
	{"test-tube", TEST_TUBE},
	{"test-tube-2", TEST_TUBE_2},
	{"test-tubes", TEST_TUBES},
	{"text-align-justify-center", TEXT_ALIGN_JUSTIFY_CENTER},
	{"text-align-justify-end", TEXT_ALIGN_JUSTIFY_END},
	{"text-align-justify-start", TEXT_ALIGN_JUSTIFY_START},
	{"text-cursor", TEXT_CURSOR},
	{"text-cursor-input", TEXT_CURSOR_INPUT},
	{"text-quote", TEXT_QUOTE},
	{"text-search", TEXT_SEARCH},
	{"text-wrap", TEXT_WRAP},
	{"theater", THEATER},
	{"thermometer", THERMOMETER},
	{"thermometer-snowflake", THERMOMETER_SNOWFLAKE},
	{"thermometer-sun", THERMOMETER_SUN},
	{"thumbs-down", THUMBS_DOWN},
	{"thumbs-up", THUMBS_UP},
	{"tic-tac-toe", TIC_TAC_TOE},
	{"ticket", TICKET},
	{"ticket-check", TICKET_CHECK},
	{"ticket-minus", TICKET_MINUS},
	{"ticket-percent", TICKET_PERCENT},
	{"ticket-plus", TICKET_PLUS},
	{"ticket-slash", TICKET_SLASH},
	{"ticket-x", TICKET_X},
	{"tickets", TICKETS},
	{"tickets-plane", TICKETS_PLANE},
	{"timeline", TIMELINE},
	{"timer", TIMER},
	{"timer-off", TIMER_OFF},
	{"timer-reset", TIMER_RESET},
	{"toggle-left", TOGGLE_LEFT},
	{"toggle-right", TOGGLE_RIGHT},
	{"toilet", TOILET},
	{"tool-case", TOOL_CASE},
	{"toolbox", TOOLBOX},
	{"toothbrush", TOOTHBRUSH},
	{"toothbrush-sparkles", TOOTHBRUSH_SPARKLES},
	{"tornado", TORNADO},
	{"torus", TORUS},
	{"touchpad", TOUCHPAD},
	{"touchpad-off", TOUCHPAD_OFF},
	{"towel-rack", TOWEL_RACK},
	{"tower-control", TOWER_CONTROL},
	{"toy-brick", TOY_BRICK},
	{"tractor", TRACTOR},
	{"traffic-cone", TRAFFIC_CONE},
	{"trailer", TRAILER},
	{"train", TRAIN},
	{"train-front", TRAIN_FRONT},
	{"train-front-tunnel", TRAIN_FRONT_TUNNEL},
	{"train-track", TRAIN_TRACK},
	{"transgender", TRANSGENDER},
	{"trash-2", TRASH_2},
	{"trash-off", TRASH_OFF},
	{"tree-deciduous", TREE_DECIDUOUS},
	{"tree-pine", TREE_PINE},
	{"trees", TREES},
	{"trending-down", TRENDING_DOWN},
	{"trending-up", TRENDING_UP},
	{"trending-up-down", TRENDING_UP_DOWN},
	{"triangle", TRIANGLE},
	{"triangle-dashed", TRIANGLE_DASHED},
	{"triangle-right", TRIANGLE_RIGHT},
	{"trophy", TROPHY},
	{"truck", TRUCK},
	{"truck-electric", TRUCK_ELECTRIC},
	{"tube-lotion", TUBE_LOTION},
	{"turkish-lira", TURKISH_LIRA},
	{"turntable", TURNTABLE},
	{"turtle", TURTLE},
	{"tv", TV},
	{"tv-2", TV_2},
	{"tv-minimal-play", TV_MINIMAL_PLAY},
	{"type", TYPE},
	{"type-outline", TYPE_OUTLINE},
	{"umbrella", UMBRELLA},
	{"umbrella-off", UMBRELLA_OFF},
	{"underline", UNDERLINE},
	{"undo", UNDO},
	{"undo-2", UNDO_2},
	{"undo-dot", UNDO_DOT},
	{"unfold-horizontal", UNFOLD_HORIZONTAL},
	{"unfold-vertical", UNFOLD_VERTICAL},
	{"ungroup", UNGROUP},
	{"unlink", UNLINK},
	{"unlink-2", UNLINK_2},
	{"unplug", UNPLUG},
	{"upload", UPLOAD},
	{"usb", USB},
	{"usb-c-port", USB_C_PORT},
	{"user", USER},
	{"user-2", USER_2},
	{"user-check", USER_CHECK},
	{"user-check-2", USER_CHECK_2},
	{"user-cog", USER_COG},
	{"user-cog-2", USER_COG_2},
	{"user-group", USER_GROUP},
	{"user-key", USER_KEY},
	{"user-lock", USER_LOCK},
	{"user-minus", USER_MINUS},
	{"user-minus-2", USER_MINUS_2},
	{"user-pen", USER_PEN},
	{"user-plus", USER_PLUS},
	{"user-plus-2", USER_PLUS_2},
	{"user-round-arrow-left", USER_ROUND_ARROW_LEFT},
	{"user-round-group", USER_ROUND_GROUP},
	{"user-round-key", USER_ROUND_KEY},
	{"user-round-pen", USER_ROUND_PEN},
	{"user-round-search", USER_ROUND_SEARCH},
	{"user-round-star", USER_ROUND_STAR},
	{"user-round-x", USER_ROUND_X},
	{"user-search", USER_SEARCH},
	{"user-shield", USER_SHIELD},
	{"user-star", USER_STAR},
	{"user-x", USER_X},
	{"users", USERS},
	{"users-2", USERS_2},
	{"utility-pole", UTILITY_POLE},
	{"van", VAN},
	{"variable", VARIABLE},
	{"vault", VAULT},
	{"vector-polygon", VECTOR_POLYGON},
	{"vector-square", VECTOR_SQUARE},
	{"vegan", VEGAN},
	{"venetian-mask", VENETIAN_MASK},
	{"venus", VENUS},
	{"venus-and-mars", VENUS_AND_MARS},
	{"vibrate", VIBRATE},
	{"vibrate-off", VIBRATE_OFF},
	{"video", VIDEO},
	{"video-off", VIDEO_OFF},
	{"videotape", VIDEOTAPE},
	{"view", VIEW},
	{"virus", VIRUS},
	{"virus-off", VIRUS_OFF},
	{"voicemail", VOICEMAIL},
	{"volleyball", VOLLEYBALL},
	{"volume", VOLUME},
	{"volume-1", VOLUME_1},
	{"volume-2", VOLUME_2},
	{"volume-off", VOLUME_OFF},
	{"volume-x", VOLUME_X},
	{"vote", VOTE},
	{"wallet", WALLET},
	{"wallet-2", WALLET_2},
	{"wallet-cards", WALLET_CARDS},
	{"wallpaper", WALLPAPER},
	{"wand", WAND},
	{"wand-2", WAND_2},
	{"warehouse", WAREHOUSE},
	{"washing-machine", WASHING_MACHINE},
	{"watch", WATCH},
	{"waves-arrow-down", WAVES_ARROW_DOWN},
	{"waves-arrow-up", WAVES_ARROW_UP},
	{"waves-horizontal", WAVES_HORIZONTAL},
	{"waves-ladder", WAVES_LADDER},
	{"waves-vertical", WAVES_VERTICAL},
	{"waypoints", WAYPOINTS},
	{"webcam", WEBCAM},
	{"webcam-off", WEBCAM_OFF},
	{"webhook", WEBHOOK},
	{"webhook-off", WEBHOOK_OFF},
	{"weight", WEIGHT},
	{"weight-tilde", WEIGHT_TILDE},
	{"wheat", WHEAT},
	{"wheat-off", WHEAT_OFF},
	{"whistle", WHISTLE},
	{"whole-word", WHOLE_WORD},
	{"wifi", WIFI},
	{"wifi-cog", WIFI_COG},
	{"wifi-high", WIFI_HIGH},
	{"wifi-lock", WIFI_LOCK},
	{"wifi-low", WIFI_LOW},
	{"wifi-off", WIFI_OFF},
	{"wifi-pen", WIFI_PEN},
	{"wifi-sync", WIFI_SYNC},
	{"wifi-zero", WIFI_ZERO},
	{"wind", WIND},
	{"wind-arrow-down", WIND_ARROW_DOWN},
	{"wind-arrow-up", WIND_ARROW_UP},
	{"wine", WINE},
	{"wine-off", WINE_OFF},
	{"workflow", WORKFLOW},
	{"worm", WORM},
	{"wrench", WRENCH},
	{"wrench-off", WRENCH_OFF},
	{"x", X},
	{"x-line-top", X_LINE_TOP},
	{"zap", ZAP},
	{"zap-off", ZAP_OFF},
	{"zodiac-aquarius", ZODIAC_AQUARIUS},
	{"zodiac-aries", ZODIAC_ARIES},
	{"zodiac-cancer", ZODIAC_CANCER},
	{"zodiac-capricorn", ZODIAC_CAPRICORN},
	{"zodiac-gemini", ZODIAC_GEMINI},
	{"zodiac-leo", ZODIAC_LEO},
	{"zodiac-libra", ZODIAC_LIBRA},
	{"zodiac-ophiuchus", ZODIAC_OPHIUCHUS},
	{"zodiac-pisces", ZODIAC_PISCES},
	{"zodiac-sagittarius", ZODIAC_SAGITTARIUS},
	{"zodiac-scorpio", ZODIAC_SCORPIO},
	{"zodiac-taurus", ZODIAC_TAURUS},
	{"zodiac-virgo", ZODIAC_VIRGO},
	{"zoom-in", ZOOM_IN},
	{"zoom-out", ZOOM_OUT},
}

// The icon named `name` (the font's name, "search", "alert-triangle"). False: no such icon in this font.
glyph_of :: proc(name: string) -> (glyph: string, ok: bool) {
	lo, hi := 0, len(NAMES)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		switch {
		case NAMES[mid].name < name: lo = mid + 1
		case NAMES[mid].name > name: hi = mid
		case:                        return NAMES[mid].glyph, true
		}
	}
	return "", false
}
