//
//  ImageDiff.metal
//  Onit
//
//  Created by Timothy Lenardo on 9/10/25.
//

#include <metal_stdlib>
using namespace metal;

struct DiffParams {
    uint width;
    uint height;
    uint tileSize;
    uint tileStrideX;
    uint tileStrideY;
    uint tilesX;
    uint tilesY;
    uint sampleStride;
    uint threshold;
    int  shiftDX;
    int  shiftDY;
};

kernel void diff_and_tile_count(
    texture2d<half, access::read> beforeTexture [[texture(0)]],
    texture2d<half, access::read> afterTexture  [[texture(1)]],
    device atomic_uint* tileChanged             [[buffer(0)]],
    device atomic_uint* tileSampled             [[buffer(1)]],
    constant DiffParams& p                      [[buffer(2)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;

    if ((gid.x % p.sampleStride) != 0 || (gid.y % p.sampleStride) != 0) return;

    int ax = int(gid.x) + p.shiftDX;
    int ay = int(gid.y) + p.shiftDY;
    if (ax < 0 || ay < 0 || ax >= int(p.width) || ay >= int(p.height)) return;

    // Before image pixel coordinates
    uint2 bxy = uint2(gid.x, gid.y);
    // After image pixel coordinates (with shift)
    uint2 axy = uint2(ax, ay);

    half4 b = beforeTexture.read(bxy);
    half4 a = afterTexture.read(axy);

    float dR = fabs((float)a.x - (float)b.x);
    float dG = fabs((float)a.y - (float)b.y);
    float dB = fabs((float)a.z - (float)b.z);
    float d  = max(dR, max(dG, dB));
    float thr = float(p.threshold) / 255.0f;

    uint tileX = gid.x / p.tileStrideX;
    uint tileY = gid.y / p.tileStrideY;
    if (tileX >= p.tilesX || tileY >= p.tilesY) return;
    uint tileIdx = tileY * p.tilesX + tileX;

    atomic_fetch_add_explicit(&tileSampled[tileIdx], 1u, memory_order_relaxed);
    if (d > thr) {
        atomic_fetch_add_explicit(&tileChanged[tileIdx], 1u, memory_order_relaxed);
    }
}

struct Shift { int dx; int dy; };

struct SSDParams {
    uint width;
    uint height;
    uint anchorX;
    uint anchorY;
    uint anchorW;
    uint anchorH;
};


kernel void ssd_anchor_kernel(
    texture2d<half, access::read> beforeTexture [[texture(0)]],
    texture2d<half, access::read> afterTexture  [[texture(1)]],
    constant Shift* shifts                      [[buffer(0)]],
    device float* outMSE                        [[buffer(1)]],
    constant SSDParams& p                       [[buffer(2)]],
    uint gid                                    [[thread_position_in_grid]])
{
    Shift s = shifts[gid];
    int x0 = max(0, -s.dx);
    int y0 = max(0, -s.dy);
    int x1 = min(int(p.anchorW), int(p.width)  - s.dx);
    int y1 = min(int(p.anchorH), int(p.height) - s.dy);
    if (x0 >= x1 || y0 >= y1) { outMSE[gid] = INFINITY; return; }

    float ssd = 0.0f;
    uint count = 0;
    for (int yy = y0; yy < y1; ++yy) {
        for (int xx = x0; xx < x1; ++xx) {
            // Before image pixel coordinates
            uint2 bxy = uint2(p.anchorX + xx, p.anchorY + yy);
            // After image pixel coordinates (with shift)
            uint2 axy = uint2(p.anchorX + xx + s.dx, p.anchorY + yy + s.dy);

            half4 b = beforeTexture.read(bxy);
            half4 a = afterTexture.read(axy);

            float dR = (float)a.x - (float)b.x;
            float dG = (float)a.y - (float)b.y;
            float dB = (float)a.z - (float)b.z;
            // Scale to match CPU range (0-255) instead of normalized (0-1)
            dR *= 255.0f;
            dG *= 255.0f;
            dB *= 255.0f;
            ssd += (dR*dR + dG*dG + dB*dB);
            count++;
        }
    }
    outMSE[gid] = count > 0 ? (ssd / float(count)) : INFINITY;
}
