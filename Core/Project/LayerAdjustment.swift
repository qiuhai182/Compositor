import Foundation

// A live adjustment layer's kind and settings: what the manifest stores and what the validity
// rules accept. The pixel pipelines that apply the settings stay in the app.

nonisolated enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case hsv = "Hue/Saturation", levels = "Levels", curves = "Curves"
    case exposure = "Exposure", gradientMap = "Gradient Map", grain = "Grain", addNoise = "Add Noise"
    case gaussianBlur = "Gaussian Blur", motionBlur = "Motion Blur"
    case invert = "Invert"
    case blackWhite = "Black & White", colorBalance = "Color Balance"
    /// The filter panel that edits this kind; Levels and Hue/Saturation have panels of their own.
    /// Every kind but Invert opens an editor when its layer is double-clicked.
    var isEditable: Bool { self != .invert }
}

nonisolated struct LayerAdjustment: Codable, Equatable, Sendable {
    var kind: AdjustmentKind
    var hue: Double = 0
    var saturation: Double = 0
    var lightness: Double = 0
    var colorize = false
    // Optional so projects saved before range-aware HSV adjustments still decode.
    var hsvSettings: HueSaturationSettings?
    var resolvedHSV: HueSaturationSettings {
        hsvSettings ?? HueSaturationSettings(hue: hue, saturation: saturation, lightness: lightness, colorize: colorize)
    }
    var levels = LevelsSettings()
    var curves = CurvesSettings()
    // Optional so projects saved before these adjustments existed decode, and save, exactly as before.
    var exposureSettings: ExposureSettings?
    var gradientMapSettings: GradientMapSettings?
    var grainSettings: GrainSettings?
    var blackWhiteSettings: BlackWhiteSettings?
    var colorBalanceSettings: ColorBalanceSettings?
    // Optional so projects created before blur adjustments continue to decode unchanged.
    var blurRadius: Double?
    var motionAngle: Double?
    var motionDistance: Double?
    var noiseAmount: Double?
    var noiseGaussian: Bool?
    var noiseMonochromatic: Bool?
    var noiseSeed: UInt32?
    var exposure: ExposureSettings {
        get { exposureSettings ?? ExposureSettings() }
        set { exposureSettings = newValue }
    }
    var gradientMap: GradientMapSettings {
        get { gradientMapSettings ?? GradientMapSettings() }
        set { gradientMapSettings = newValue }
    }
    var grain: GrainSettings {
        get { grainSettings ?? GrainSettings() }
        set { grainSettings = newValue }
    }
    var blackWhite: BlackWhiteSettings {
        get { blackWhiteSettings ?? BlackWhiteSettings() }
        set { blackWhiteSettings = newValue }
    }
    var colorBalance: ColorBalanceSettings {
        get { colorBalanceSettings ?? ColorBalanceSettings() }
        set { colorBalanceSettings = newValue }
    }
    var gaussianRadius: Double {
        get { blurRadius ?? 10 }
        set { blurRadius = newValue }
    }
    var resolvedMotionAngle: Double {
        get { motionAngle ?? 0 }
        set { motionAngle = newValue }
    }
    var resolvedMotionDistance: Double {
        get { motionDistance ?? 10 }
        set { motionDistance = newValue }
    }
    var resolvedNoiseAmount: Double {
        get { noiseAmount ?? 10 }
        set { noiseAmount = newValue }
    }
    var resolvedNoiseGaussian: Bool {
        get { noiseGaussian ?? false }
        set { noiseGaussian = newValue }
    }
    var resolvedNoiseMonochromatic: Bool {
        get { noiseMonochromatic ?? false }
        set { noiseMonochromatic = newValue }
    }
    var resolvedNoiseSeed: UInt32 {
        get { noiseSeed ?? 0 }
        set { noiseSeed = newValue }
    }
    /// Document-pixel halo needed so a partial canvas redraw can sample beyond its dirty rectangle.
    var samplingMargin: CGFloat {
        switch kind {
        case .gaussianBlur: return CGFloat(gaussianRadius * 3 + 2)
        case .motionBlur: return CGFloat(resolvedMotionDistance / 2 + 2)
        default: return 0
        }
    }
    var isValid: Bool {
        hue.isFinite && saturation.isFinite && lightness.isFinite && abs(hue) <= 360 && abs(saturation) <= 100 && abs(lightness) <= 100
        && resolvedHSV.adjustments.values.allSatisfy {
            $0.hue.isFinite && abs($0.hue) <= 360 && $0.saturation.isFinite && abs($0.saturation) <= 100
                && $0.lightness.isFinite && abs($0.lightness) <= 100
        }
        && resolvedHSV.bands.values.allSatisfy { $0.handles.allSatisfy { $0.isFinite } }
        && levels.ranges.count == 4 && levels.ranges.allSatisfy { $0 == $0.normalized } && curves.isValid
        && exposure.isValid && gradientMap.isValid && grain.isValid && blackWhite.isValid && colorBalance.isValid
        && gaussianRadius.isFinite && (0.1...250).contains(gaussianRadius)
        && resolvedMotionAngle.isFinite && (-90...90).contains(resolvedMotionAngle)
        && resolvedMotionDistance.isFinite && (1...2000).contains(resolvedMotionDistance)
        && resolvedNoiseAmount.isFinite && (0.1...400).contains(resolvedNoiseAmount)
    }
}
