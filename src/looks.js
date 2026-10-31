export const looks = [
  {
    id: "newsprint",
    name: "Newsprint",
    stack: [
      {
        kind: "colorControls",
        values: {
          inputSaturation: 0.0,
          inputContrast: 1.15,
        },
      },
      {
        kind: "halftoneDots",
        values: {
          inputWidth: 6.0,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.12,
        },
      },
    ],
  },
  {
    id: "riso",
    name: "Riso Print",
    stack: [
      {
        kind: "posterize",
        values: {
          inputLevels: 4.0,
        },
      },
      {
        kind: "gradientMap",
        values: {
          shadow: {
            r: 0.1,
            g: 0.12,
            b: 0.45,
            a: 1,
          },
          highlight: {
            r: 1.0,
            g: 0.45,
            b: 0.55,
            a: 1,
          },
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.18,
        },
      },
    ],
  },
  {
    id: "vhs",
    name: "VHS",
    stack: [
      {
        kind: "chromaticAberration",
        values: {
          amount: 5.0,
        },
      },
      {
        kind: "scanlines",
        values: {
          spacing: 4.0,
          intensity: 0.35,
        },
      },
      {
        kind: "blur",
        values: {
          inputRadius: 1.2,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 1.2,
          inputRadius: 1.6,
        },
      },
    ],
  },
  {
    id: "cyberpunk",
    name: "Cyberpunk",
    stack: [
      {
        kind: "glitch",
        values: {
          amount: 0.45,
          seed: 7.0,
        },
      },
      {
        kind: "chromaticAberration",
        values: {
          amount: 8.0,
        },
      },
      {
        kind: "bloom",
        values: {
          inputRadius: 12.0,
          inputIntensity: 1.2,
        },
      },
    ],
  },
  {
    id: "comicbook",
    name: "Comic Book",
    stack: [
      {
        kind: "comic",
        values: {},
      },
      {
        kind: "colorHalftone",
        values: {
          inputWidth: 8.0,
        },
      },
    ],
  },
  {
    id: "pixelart",
    name: "Pixel Art",
    stack: [
      {
        kind: "mosaic",
        values: {
          inputScale: 16.0,
        },
      },
      {
        kind: "posterize",
        values: {
          inputLevels: 6.0,
        },
      },
    ],
  },
  {
    id: "dream",
    name: "Dream",
    stack: [
      {
        kind: "bloom",
        values: {
          inputRadius: 20.0,
          inputIntensity: 1.4,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.08,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 0.9,
          inputRadius: 2.0,
        },
      },
    ],
  },
  {
    id: "silver",
    name: "Silver",
    stack: [
      {
        kind: "colorControls",
        values: {
          inputSaturation: 0.0,
          inputContrast: 1.1,
        },
      },
      {
        kind: "sharpenLuminance",
        values: {
          inputSharpness: 0.6,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.15,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 1.1,
          inputRadius: 1.8,
        },
      },
    ],
  },
  {
    id: "goldenhour",
    name: "Golden Hour",
    stack: [
      {
        kind: "whiteBalance",
        values: {
          temp: 8200.0,
        },
      },
      {
        kind: "vibrance",
        values: {
          inputAmount: 0.25,
        },
      },
      {
        kind: "highlightShadow",
        values: {
          inputShadowAmount: 0.2,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 0.7,
          inputRadius: 2.2,
        },
      },
    ],
  },
  {
    id: "polaroid",
    name: "Polaroid",
    stack: [
      {
        kind: "filmInstant",
        values: {},
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.1,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 0.9,
          inputRadius: 1.9,
        },
      },
    ],
  },
  {
    id: "noir",
    name: "Noir",
    stack: [
      {
        kind: "filmNoir",
        values: {},
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.16,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 1.4,
          inputRadius: 1.6,
        },
      },
    ],
  },
  {
    id: "fadedfilm",
    name: "Faded Film",
    stack: [
      {
        kind: "filmFade",
        values: {},
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.12,
        },
      },
      {
        kind: "whiteBalance",
        values: {
          temp: 7200.0,
        },
      },
    ],
  },
  {
    id: "tealorange",
    name: "Teal & Orange",
    stack: [
      {
        kind: "splitTone",
        values: {
          shadowColor: {
            r: 0.05,
            g: 0.35,
            b: 0.45,
            a: 1,
          },
          highlightColor: {
            r: 1.0,
            g: 0.62,
            b: 0.28,
            a: 1,
          },
          amount: 0.7,
        },
      },
      {
        kind: "vibrance",
        values: {
          inputAmount: 0.25,
        },
      },
      {
        kind: "clarity",
        values: {
          amount: 0.35,
        },
      },
    ],
  },
  {
    id: "cinematic",
    name: "Cinematic",
    stack: [
      {
        kind: "highlightShadow",
        values: {
          inputShadowAmount: 0.25,
          inputHighlightAmount: 0.85,
        },
      },
      {
        kind: "splitTone",
        values: {
          shadowColor: {
            r: 0.1,
            g: 0.2,
            b: 0.38,
            a: 1,
          },
          highlightColor: {
            r: 0.95,
            g: 0.8,
            b: 0.55,
            a: 1,
          },
          amount: 0.5,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 1.0,
          inputRadius: 2.0,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.07,
        },
      },
    ],
  },
  {
    id: "matte",
    name: "Matte",
    stack: [
      {
        kind: "levels",
        values: {
          outBlack: 0.08,
          outWhite: 0.97,
        },
      },
      {
        kind: "colorControls",
        values: {
          inputSaturation: 0.9,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.08,
        },
      },
    ],
  },
  {
    id: "lomo",
    name: "Lomo",
    stack: [
      {
        kind: "colorControls",
        values: {
          inputSaturation: 1.3,
          inputContrast: 1.2,
        },
      },
      {
        kind: "curves",
        values: {
          y0: 0.04,
          y1: 0.2,
          y3: 0.82,
          y4: 0.98,
        },
      },
      {
        kind: "vignette",
        values: {
          inputIntensity: 1.8,
          inputRadius: 1.4,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.12,
        },
      },
    ],
  },
  {
    id: "sunburst",
    name: "Sunburst",
    stack: [
      {
        kind: "whiteBalance",
        values: {
          temp: 9000.0,
        },
      },
      {
        kind: "vibrance",
        values: {
          inputAmount: 0.35,
        },
      },
      {
        kind: "bloom",
        values: {
          inputRadius: 8.0,
          inputIntensity: 0.7,
        },
      },
    ],
  },
  {
    id: "arctic",
    name: "Arctic",
    stack: [
      {
        kind: "whiteBalance",
        values: {
          temp: 4800.0,
        },
      },
      {
        kind: "vibrance",
        values: {
          inputAmount: 0.2,
        },
      },
      {
        kind: "clarity",
        values: {
          amount: 0.4,
        },
      },
    ],
  },
  {
    id: "bleach",
    name: "Bleach Bypass",
    stack: [
      {
        kind: "colorControls",
        values: {
          inputSaturation: 0.35,
          inputContrast: 1.35,
        },
      },
      {
        kind: "sharpenLuminance",
        values: {
          inputSharpness: 0.5,
        },
      },
      {
        kind: "grain",
        values: {
          grainAmount: 0.14,
        },
      },
    ],
  },
  {
    id: "crisp",
    name: "Crisp Air",
    stack: [
      {
        kind: "dehaze",
        values: {
          amount: 0.55,
        },
      },
      {
        kind: "clarity",
        values: {
          amount: 0.45,
        },
      },
      {
        kind: "vibrance",
        values: {
          inputAmount: 0.15,
        },
      },
    ],
  },
];
