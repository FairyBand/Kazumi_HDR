//!PARAM warm_chroma_boost
//!DESC Warm color chroma boost
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.6
0.22

//!PARAM warm_luma_boost
//!DESC Warm color luma boost
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.4
0.04

//!PARAM dark_color_lift
//!DESC Dark saturated color lift
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.4
0.10

//!PARAM transition_soften
//!DESC Soft transition chroma smoothing
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.6
0.12

//!PARAM transition_threshold
//!DESC Soft transition edge threshold
//!TYPE float
//!MINIMUM 0.001
//!MAXIMUM 0.2
0.035

//!PARAM cool_chroma_restore
//!DESC Blue/cyan chroma restore
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.8
0.28

//!PARAM cool_luma_density
//!DESC Blue/cyan luma density
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.5
0.10

//!PARAM pink_chroma_restore
//!DESC Pale pink chroma restore
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.2
0.42

//!PARAM pink_luma_density
//!DESC Pale pink luma density
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.5
0.12

//!HOOK PREOUTPUT
//!BIND HOOKED
//!DESC Transition-aware color/luma remap prototype

const vec3 LUMA_BT2020 = vec3(0.2627, 0.6780, 0.0593);

float luma2020(vec3 c)
{
    return dot(c, LUMA_BT2020);
}

float saturation(vec3 c)
{
    float hi = max(max(c.r, c.g), c.b);
    float lo = min(min(c.r, c.g), c.b);
    return (hi - lo) / max(hi, 1e-5);
}

vec3 set_luma(vec3 c, float target_y)
{
    float y = max(luma2020(c), 1e-5);
    return c * (target_y / y);
}

float warm_yellow_orange_mask(vec3 c, float y, float sat)
{
    float rb = c.r - c.b;
    float gb = c.g - c.b;
    float rg_delta = abs(c.r - c.g) / max(max(c.r, c.g), 1e-5);
    float rg_balance = 1.0 - smoothstep(0.30, 0.80, rg_delta);
    float not_skin = smoothstep(0.20, 0.55, sat);
    float hue = smoothstep(0.01, 0.12, rb) * smoothstep(0.01, 0.12, gb) * rg_balance;
    float level = smoothstep(0.08, 0.35, y);
    float vivid = smoothstep(0.22, 0.58, sat);
    return hue * level * vivid * not_skin;
}

float dark_saturated_mask(float y, float sat)
{
    float dark = 1.0 - smoothstep(0.08, 0.32, y);
    float vivid = smoothstep(0.12, 0.50, sat);
    return dark * vivid;
}

float cool_blue_cyan_mask(vec3 c, float y, float sat)
{
    float blue_lead = c.b - max(c.r, c.g);
    float cyan_lead = min(c.g, c.b) - c.r;
    float blue_hue = smoothstep(0.02, 0.18, blue_lead);
    float cyan_hue = smoothstep(0.02, 0.20, cyan_lead) * smoothstep(-0.08, 0.12, c.b - c.g);
    float hue = max(blue_hue, cyan_hue);
    float level = smoothstep(0.04, 0.45, y) * (1.0 - smoothstep(0.92, 1.30, y));
    float vivid = smoothstep(0.10, 0.42, sat);
    return hue * level * vivid;
}

float pale_pink_mask(vec3 c, float y, float sat)
{
    float red_lead = c.r - max(c.g, c.b);
    float red_hue = smoothstep(0.004, 0.075, red_lead);
    float blue_green_balance = smoothstep(0.68, 0.94, c.b / max(c.g, 1e-5));
    float not_yellow_orange = 1.0 - smoothstep(0.12, 0.36, c.g - c.b);
    float light_surface = smoothstep(0.28, 0.78, y) * (1.0 - smoothstep(1.15, 1.60, y));
    float pale_color = smoothstep(0.015, 0.11, sat) * (1.0 - smoothstep(0.55, 0.85, sat));
    return red_hue * blue_green_balance * not_yellow_orange * light_surface * pale_color;
}

vec4 hook()
{
    vec4 encoded = HOOKED_texOff(vec2(0.0));
    vec4 linear = linearize(encoded);
    vec3 c = max(linear.rgb, vec3(0.0));

    float y = luma2020(c);
    float sat = saturation(c);
    vec3 neutral = vec3(y);
    vec3 chroma = c - neutral;

    float warm = warm_yellow_orange_mask(c, y, sat);
    float dark_sat = dark_saturated_mask(y, sat);
    float cool = cool_blue_cyan_mask(c, y, sat);
    float pink = pale_pink_mask(c, y, sat);

    vec3 n1 = max(linearize(HOOKED_texOff(vec2( 1.0,  0.0))).rgb, vec3(0.0));
    vec3 n2 = max(linearize(HOOKED_texOff(vec2(-1.0,  0.0))).rgb, vec3(0.0));
    vec3 n3 = max(linearize(HOOKED_texOff(vec2( 0.0,  1.0))).rgb, vec3(0.0));
    vec3 n4 = max(linearize(HOOKED_texOff(vec2( 0.0, -1.0))).rgb, vec3(0.0));

    vec3 avg = 0.25 * (n1 + n2 + n3 + n4);
    float avg_y = luma2020(avg);
    vec3 avg_chroma = avg - vec3(avg_y);

    float grad_y = abs(y - avg_y);
    float grad_c = length(chroma - avg_chroma);
    float soft_region = 1.0 - smoothstep(transition_threshold, transition_threshold * 3.0, grad_y + 0.35 * grad_c);
    float soften = transition_soften * soft_region * smoothstep(0.08, 0.45, sat);

    chroma = mix(chroma, avg_chroma, soften);
    chroma *= 1.0 + warm_chroma_boost * warm;
    chroma *= 1.0 + cool_chroma_restore * cool;
    chroma *= 1.0 + pink_chroma_restore * pink;

    vec3 outc = vec3(y) + chroma;

    float warm_target_y = y * (1.0 + warm_luma_boost * warm);
    float cool_target_y = warm_target_y * (1.0 - cool_luma_density * cool * smoothstep(0.25, 1.05, y));
    float pink_target_y = cool_target_y * (1.0 - pink_luma_density * pink * smoothstep(0.35, 1.10, y));
    float dark_target_y = mix(pink_target_y, max(pink_target_y, 0.75 * y + 0.25 * 0.18), dark_color_lift * dark_sat * (1.0 - 0.5 * cool) * (1.0 - 0.5 * pink));
    float final_target_y = dark_target_y;
    outc = set_luma(max(outc, vec3(0.0)), final_target_y);

    return delinearize(vec4(max(outc, vec3(0.0)), encoded.a));
}
