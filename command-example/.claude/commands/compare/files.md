Compare two files and explain the meaningful differences.

Arguments: $ARGUMENTS
Expected format: two file paths separated by a space, e.g. `src/old.py src/new.py`

Steps:
1. Parse the two paths from $ARGUMENTS (first token = file A, second token = file B)
2. Read both files
3. Identify what changed: additions, removals, renames, logic changes
4. Summarise the differences under these headings:
   - **Added** — new functions, classes, or blocks
   - **Removed** — deleted code
   - **Changed** — modified logic or signatures
   - **Cosmetic** — formatting, comments, imports reordered (de-emphasise these)

If either path is missing or the file does not exist, say so clearly and stop.
