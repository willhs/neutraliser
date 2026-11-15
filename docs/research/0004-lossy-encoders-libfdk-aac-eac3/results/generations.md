| Source | Gen | Encoder, target kbit/s | Stamp first-gen kbit/s read | File kbit/s | ViSQOL | SNR dB | ViSQOL change from previous gen (per window: min to max) | SNR change |
|---|---|---|---|---|---|---|---|---|
| aac_20_128 | 1 | aac 160/161/161/161 | none (no stamp) | 166 | 4.570 | 24.6 | - | - |
| aac_20_128 | 2 | aac 160/161/161/161 | 128/129/129/129 | 166 | 4.389 | 21.1 | -0.180 (-0.207 to -0.156) | -3.5 |
| aac_20_128 | 3 | aac 160/161/161/161 | 128/129/129/129 | 166 | 4.246 | 19.2 | -0.144 (-0.164 to -0.112) | -1.8 |
| aac_51_384 | 1 | aac 480/480/482/482 | none (no stamp) | 485 | 4.621 | 24.3 | - | - |
| aac_51_384 | 2 | aac 480/480/482/482 | 384/384/386/386 | 486 | 4.534 | 22.5 | -0.087 (-0.096 to -0.078) | -1.8 |
| aac_51_384 | 3 | aac 480/480/482/482 | 384/384/386/386 | 486 | 4.443 | 21.6 | -0.091 (-0.097 to -0.080) | -0.9 |
| ac3_51_448 | 1 | ac3 576 | none (no stamp) | 578 | 4.599 | 29.0 | - | - |
| ac3_51_448 | 2 | ac3 576 | 448 | 578 | 4.558 | 28.8 | -0.041 (-0.052 to -0.033) | -0.2 |
| ac3_51_448 | 3 | ac3 576 | 448 | 578 | 4.519 | 28.8 | -0.039 (-0.062 to -0.029) | -0.0 |
| eac3_51_640 | 1 | eac3 800 | none (no stamp) | 802 | 4.659 | 32.1 | - | - |
| eac3_51_640 | 2 | eac3 800 | 640 | 802 | 4.612 | 32.3 | -0.046 (-0.051 to -0.042) | +0.1 |
| eac3_51_640 | 3 | eac3 800 | 640 | 802 | 4.561 | 32.4 | -0.051 (-0.066 to -0.045) | +0.1 |

Generation 1 to 3, paired per window:
- aac_20_128: ViSQOL -0.324 (-0.367 to -0.286), SNR -5.4 dB
- aac_51_384: ViSQOL -0.178 (-0.189 to -0.168), SNR -2.7 dB
- ac3_51_448: ViSQOL -0.080 (-0.114 to -0.063), SNR -0.2 dB
- eac3_51_640: ViSQOL -0.097 (-0.109 to -0.089), SNR +0.3 dB

Bitrate check, every window: generation N target == generation 1 target?
- aac_20_128 w200: targets [160928, 160928, 160928], first-generation figure read by pass [128742, 128742, 128742], lag [1024, 2048, 3072]
- aac_20_128 w380: targets [160949, 160949, 160949], first-generation figure read by pass [128759, 128759, 128759], lag [1024, 2048, 3072]
- aac_20_128 w520: targets [160874, 160874, 160874], first-generation figure read by pass [128699, 128699, 128699], lag [1024, 2048, 3072]
- aac_20_128 w60: targets [159997, 159997, 159997], first-generation figure read by pass [127997, 127997, 127997], lag [1024, 2048, 3072]
- aac_51_384 w200: targets [480288, 480288, 480288], first-generation figure read by pass [384230, 384230, 384230], lag [1024, 2048, 3072]
- aac_51_384 w380: targets [482283, 482283, 482283], first-generation figure read by pass [385826, 385826, 385826], lag [1024, 2048, 3072]
- aac_51_384 w520: targets [482178, 482178, 482178], first-generation figure read by pass [385742, 385742, 385742], lag [1024, 2048, 3072]
- aac_51_384 w60: targets [480008, 480008, 480008], first-generation figure read by pass [384006, 384006, 384006], lag [1024, 2048, 3072]
- ac3_51_448 w200: targets [576000, 576000, 576000], first-generation figure read by pass [448000, 448000, 448000], lag [256, 512, 768]
- ac3_51_448 w380: targets [576000, 576000, 576000], first-generation figure read by pass [448000, 448000, 448000], lag [256, 512, 768]
- ac3_51_448 w520: targets [576000, 576000, 576000], first-generation figure read by pass [448000, 448000, 448000], lag [256, 512, 768]
- ac3_51_448 w60: targets [576000, 576000, 576000], first-generation figure read by pass [448000, 448000, 448000], lag [256, 512, 768]
- eac3_51_640 w200: targets [800000, 800000, 800000], first-generation figure read by pass [640000, 640000, 640000], lag [256, 512, 768]
- eac3_51_640 w380: targets [800000, 800000, 800000], first-generation figure read by pass [640000, 640000, 640000], lag [256, 512, 768]
- eac3_51_640 w520: targets [800000, 800000, 800000], first-generation figure read by pass [640000, 640000, 640000], lag [256, 512, 768]
- eac3_51_640 w60: targets [800000, 800000, 800000], first-generation figure read by pass [640000, 640000, 640000], lag [256, 512, 768]
