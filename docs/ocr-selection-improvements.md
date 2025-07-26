# OCR Selection Experience Improvements

## Problem
The original OCR area selection experience had issues where users couldn't see the selection box while dragging, making it difficult to understand what area was being selected.

## Solution
Implemented a live preview system that shows the selection box in real-time during mouse dragging:

### Key Changes

1. **Added Temporary Selection Preview**
   - Added `temporarySelectionRect` property to show live preview during dragging
   - Selection box appears immediately when user starts dragging
   - Temporary selection is drawn with same visual style as finalized selection

2. **Improved Drawing Logic**
   - Modified `draw()` method to prioritize temporary selection during dragging
   - Control points only shown for finalized selections, not temporary ones
   - Reduced minimum size threshold for better responsiveness during dragging

3. **Enhanced Mouse Handling**
   - `mouseDragged`: Creates and updates temporary selection in real-time
   - `mouseUp`: Finalizes temporary selection if it meets minimum size requirements
   - Better coordinate clamping to video display area

4. **Visual Feedback**
   - Thick yellow dashed border with white inner border for high visibility
   - Yellow control points with black borders for resize handles
   - Red debug outline showing video display area bounds
   - Clear instructions shown at top of overlay

### User Experience
- **Before**: No visual feedback during dragging, selection only appeared after mouse release
- **After**: Immediate visual feedback showing exactly what area will be selected
- Users can now see the selection box as they drag, making the selection process intuitive
- Selection box appears with Preview.app-like behavior

### Technical Details
- Temporary selection uses display coordinates for smooth dragging
- Proper cleanup of temporary selection on ESC key or view dismissal
- Maintains backwards compatibility with existing selection logic
- All changes contained within `TextSelectionOverlayView` class

## Testing
- Compile-tested with no errors
- Ready for user testing to confirm improved selection experience
- Debug logging in place for troubleshooting if needed

## Next Steps
- User testing to confirm selection visibility across different scenarios
- Remove/reduce debug logging once confirmed working
- Optional: Add more visual enhancements if requested
