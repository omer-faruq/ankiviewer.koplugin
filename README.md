# Anki Viewer plugin for KOReader

## Overview

This plugin lets you study Anki-style flashcards directly in KOReader.

Cards are imported from standard Anki `.apkg` export files into a local database on your device. After import, you can review cards offline using a simple study screen.

## Where to put `.apkg` files

Anki Viewer looks for Anki packages in a dedicated **shared** folder inside KOReader's data directory:

```text
<KOReader data directory>/ankiviewer/shared
```

Typical locations by platform:

- **On e‑readers / most portable builds**  
  The KOReader data directory is usually the main `koreader` folder.  
  Put your files in:
  ```text
  koreader/ankiviewer/shared
  ```
  For example:
  ```text
  koreader/ankiviewer/shared/My_Deck.apkg
  koreader/ankiviewer/shared/Japanese_Words.apkg
  ```

- **When `KO_HOME` is set (desktop / special setups)**  
  If you start KOReader with `KO_HOME=/some/path`, then the plugin will look in:
  ```text
  /some/path/ankiviewer/shared
  ```

If the `ankiviewer` or `shared` folders do not exist, the plugin will create them automatically on first run. You only need to make sure the `.apkg` files themselves are copied into the `shared` folder.

## Basic usage

1. **Copy decks**  
   Export one or more decks from the Anki desktop or mobile app as `.apkg` files and copy them into the `ankiviewer/shared` folder as described above.  
   You can also download many ready-made shared decks from AnkiWeb: https://ankiweb.net/shared/decks

2. **Open the plugin**  
   - In KOReader's main menu, open **Tools > Anki Viewer** (or the equivalent entry for this plugin).

3. **Import a deck**  
   - From the study screen, tap **Import**.  
   - The plugin will list all `.apkg` files found in `ankiviewer/shared`.  
   - Choose a file to import. The cards will be converted into a local KOReader deck.

4. **Configure field mapping (optional but recommended)**  
   - Different Anki decks use different fields (front, back, examples, hints, etc.).  
   - Use the **Settings** button on the study screen to open the field mapping dialog for the current deck.  
   - There you can choose which Anki fields should appear on the **front** and **back** of the KOReader cards.

5. **Study**  
   - Use the **Decks** button to pick which deck to review.  
   - Tap **Show answer** to reveal the back of the card.  
   - Rate the card (**Again / Hard / Good / Easy**) to schedule future reviews.
   - **Delete** individual cards directly from the study screen if needed.
   - Tap on the card content to view the full text in a scrollable popup (useful for long cards).

Imported decks and review progress are stored in KOReader's data directory; removing the original `.apkg` file from `ankiviewer/shared` does **not** delete the already-imported deck.

## Features

- **Fullscreen Study Mode** – Toggle fullscreen mode in Settings to maximize card display area. Takes effect on next study session.
- **Minimum Interval Setting** – Set a minimum interval (1d, 3d, 7d, 14d) to prevent cards from being reviewed too frequently. The minimum applies to the "Again" rating, with other ratings scaling proportionally.
- **Delete Cards** – Remove individual cards from the study screen with a confirmation dialog.
- **Tap to View Full Text** – Tap on card content to view complete text in a scrollable popup.
- **Enhanced Touch Areas** – Rating button tap areas extend upward to include interval labels for easier tapping.
- **Randomize Cards** – Optionally randomize cards with the same due date.
- **Daily New Card Limit** – Control how many new cards you see per day.
- **Field Mapping** – Customize which Anki fields appear on the front and back of cards.

## Notes and limitations

- The plugin currently focuses on **local study** of imported decks.  
- Some advanced Anki features (complex templates, add-ons, custom schedulers, etc.) may not be fully reproduced; the plugin converts cards to simple front/back pairs suitable for e‑ink reading.

## Credits

This Anki Viewer plugin and its documentation were prepared with the assistance of **Windsurf (AI)**.
