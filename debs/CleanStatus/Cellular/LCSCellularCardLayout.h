#pragma once
#include <stdbool.h>
#include <math.h>
#include "LCSCellularPolicy.h"

// Video-aligned points at standard text size: 336 x 216; no settings-sheet chrome.
#define LCS_CELLULAR_CARD_WIDTH 336.0
#define LCS_CELLULAR_CARD_RADIUS 38.0
#define LCS_CELLULAR_CARD_HEADER 96.0
#define LCS_CELLULAR_CARD_ROW 60.0
#define LCS_CELLULAR_CARD_GLYPH 22.0
#define LCS_CELLULAR_CARD_PILL_FONT 12.0
#define LCS_CELLULAR_CARD_NAME_FONT 14.0
#define LCS_CELLULAR_CARD_TITLE_FONT 16.0

typedef enum {
    LCSCellularBadgeUnknown=0,LCSCellularBadgeSIMOn,LCSCellularBadgeSIMOff,
    LCSCellularBadgeDataCurrent,LCSCellularBadgeDataOther
} LCSCellularBadge;
static inline double LCSCellularCardScale(double value) {
    return !isfinite(value)||value<1?1:(value>2.5?2.5:value);
}
static inline double LCSCellularCardHeaderHeight(double scale) {
    return LCS_CELLULAR_CARD_HEADER+32*(LCSCellularCardScale(scale)-1);
}
static inline double LCSCellularCardRowHeight(double scale) {
    return LCS_CELLULAR_CARD_ROW*LCSCellularCardScale(scale);
}
static inline double LCSCellularCardHeight(double scale) {
    return LCSCellularCardHeaderHeight(scale)+2*LCSCellularCardRowHeight(scale);
}
static inline LCSCellularBadge LCSCellularCardBadge(int kind,bool known,bool observed) {
    if(!LCSCellularKindValid(kind)||!known)return LCSCellularBadgeUnknown;
    if(kind==LCSCellularSIMManager)return observed?LCSCellularBadgeSIMOn:LCSCellularBadgeSIMOff;
    return observed?LCSCellularBadgeDataCurrent:LCSCellularBadgeDataOther;
}
static inline bool LCSCellularCardBadgeGreen(LCSCellularBadge badge) {
    return badge==LCSCellularBadgeSIMOn||badge==LCSCellularBadgeDataCurrent;
}
