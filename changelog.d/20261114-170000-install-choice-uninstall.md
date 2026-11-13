type: Fixed

**An uninstall from the Installation page is a choice to run standalone: the next start offers no install.** It left the earlier answer ("installed"), and the offer came back at the next start. The offer obeys `install.choice`'s value for the run (the command line's over the user's file), as `prefs_page.install_choice` gives it; `prefs_page.choice_after` says what each event leaves. `crash.end_session` writes its files on a thread of its own, not on the thread that ran the interface.
