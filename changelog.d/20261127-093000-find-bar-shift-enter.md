type: Fixed

**An open find bar no longer takes Shift+Enter from other fields.** While a view's find bar was open, Shift+Enter typed in
any field built after it (a message composer, a multi-line field) did nothing: the bar took the key even without the
focus. The bar now asks for it only while its own field has the focus. A parts field's open list and a card stack no
longer take Escape, Left or Right they do not use.
