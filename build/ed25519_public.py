# SPDX-License-Identifier: AGPL-3.0-or-later
"""Gibt den öffentlichen Ed25519-Schlüssel (base64, Format SUPublicEDKey) zum privaten Sparkle-Schlüssel aus
SPARKLE_PRIVATE_KEY (base64-Seed, wie generate_keys -x) aus – RFC 8032, ohne Zusatzpakete.

    SPARKLE_PRIVATE_KEY=… python3 build/ed25519_public.py

Die Punktarithmetik folgt der Referenzimplementierung in RFC 8032, Abschnitt 6 (gekürzt, nur Schlüsselableitung).
Für diese Teile gilt zusätzlich die Lizenz für Code-Komponenten aus RFC 8032 (IETF Trust Legal Provisions, 4.e):

  Copyright (c) 2017 IETF Trust and the persons identified as authors of the code. All rights reserved.

  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
  following conditions are met:
  - Redistributions of source code must retain the above copyright notice, this list of conditions and the
    following disclaimer.
  - Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
    following disclaimer in the documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the names of specific contributors, may be used
    to endorse or promote products derived from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
  PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
  GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
  LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""
import base64
import hashlib
import os

seed = base64.b64decode(os.environ["SPARKLE_PRIVATE_KEY"])
p = 2**255 - 19; d = -121665 * pow(121666, p - 2, p) % p; q = 2**252 + 27742317777372353535851937790883648493
def add(P, Q):
    x1, y1, z1, t1 = P; x2, y2, z2, t2 = Q
    a = (y1 - x1) * (y2 - x2) % p; b = (y1 + x1) * (y2 + x2) % p; c = 2 * t1 * t2 * d % p; dd = 2 * z1 * z2 % p
    e, f, g, h = b - a, dd - c, dd + c, b + a
    return (e * f % p, g * h % p, f * g % p, e * h % p)
def mul(s, P):
    Q = (0, 1, 1, 0)
    while s:
        if s & 1: Q = add(Q, P)
        P = add(P, P); s >>= 1
    return Q
gy = 4 * pow(5, p - 2, p) % p
gx2 = (gy * gy - 1) * pow(d * gy * gy + 1, p - 2, p) % p
gx = pow(gx2, (p + 3) // 8, p)
if (gx * gx - gx2) % p: gx = gx * pow(2, (p - 1) // 4, p) % p
if gx & 1: gx = p - gx
G = (gx, gy, 1, gx * gy % p)
h = hashlib.sha512(seed).digest()
a = int.from_bytes(h[:32], "little"); a &= (1 << 254) - 8; a |= 1 << 254
X, Y, Z, _ = mul(a, G); zi = pow(Z, p - 2, p); x, y = X * zi % p, Y * zi % p
public = (y | ((x & 1) << 255)).to_bytes(32, "little")
print(base64.b64encode(public).decode())
