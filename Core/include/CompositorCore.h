// Umbrella header for the package's C pixel kernels (Core/Filters/C). SwiftPM exposes the C
// half of the mixed CompositorCore target to its Swift sources through this header; the app
// and compositor-mcp targets see the same declarations through their bridging header.
#ifndef CompositorCore_h
#define CompositorCore_h

#include "BrushPixels.h"
#include "HealPixels.h"
#include "LevelsPixels.h"
#include "WandPixels.h"
#include "NoisePixels.h"
#include "LensPixels.h"
#include "ContentFill.h"
#include "AdjustPixels.h"
#include "DitherPixels.h"
#include "TextPixels.h"

#endif
