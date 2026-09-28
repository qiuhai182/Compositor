// The pixel kernels are portable C shared with the CompositorCore package (Core/Filters/C),
// which is why they sit in Core/. Their headers are in Core/include so SwiftPM exposes them
// to the package's Swift sources.
#import "../Core/include/BrushPixels.h"
#import "../Core/include/HealPixels.h"
#import "../Core/include/LevelsPixels.h"
#import "../Core/include/WandPixels.h"
#import "../Core/include/NoisePixels.h"
#import "../Core/include/LensPixels.h"
#import "../Core/include/ContentFill.h"
#import "../Core/include/AdjustPixels.h"
#import "../Core/include/DitherPixels.h"
#import "../Core/include/TextPixels.h"
