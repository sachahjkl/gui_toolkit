# The licence card's reference pictures

`licence_card_test.odin` compares the card on a panel of the Midnight theme, dark and light, in each finish, with these
files: `<dark|light>_<finish>_foil.png` (the shader's foil, where the backend has it) and `<dark|light>_<finish>_flat.png`
(the flat card). `TOOLKIT_TEST_UPDATE=1 odin run tools/run_tests -- licence_card` writes them; review them like code.
