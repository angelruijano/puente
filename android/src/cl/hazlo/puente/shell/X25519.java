package cl.hazlo.puente.shell;

import java.math.BigInteger;

/**
 * X25519 (RFC 7748) para las llaves efímeras del enlace: cada conexión acuerda un secreto nuevo,
 * así una llave compartida filtrada no sirve para descifrar sesiones grabadas (secreto hacia adelante).
 * Implementación directa con BigInteger: una vez por conexión, sin depender del proveedor de Android.
 */
final class X25519 {
    private static final BigInteger P = BigInteger.ONE.shiftLeft(255).subtract(BigInteger.valueOf(19));
    private static final BigInteger A24 = BigInteger.valueOf(121665);
    private static final byte[] BASE = new byte[32];
    static { BASE[0] = 9; }

    static byte[] publicKey(byte[] priv) { return mult(priv, BASE); }

    static byte[] shared(byte[] priv, byte[] peerPub) { return mult(priv, peerPub); }

    private static byte[] mult(byte[] scalar, byte[] u) {
        byte[] k = scalar.clone();
        k[0] &= (byte) 248; k[31] &= 127; k[31] |= 64;
        byte[] uu = u.clone();
        uu[31] &= 127;
        BigInteger x1 = le(uu).mod(P), x2 = BigInteger.ONE, z2 = BigInteger.ZERO, x3 = x1, z3 = BigInteger.ONE;
        int swap = 0;
        for (int t = 254; t >= 0; t--) {
            int kt = (k[t >>> 3] >>> (t & 7)) & 1;
            swap ^= kt;
            if (swap == 1) { BigInteger a = x2; x2 = x3; x3 = a; a = z2; z2 = z3; z3 = a; }
            swap = kt;
            BigInteger a = x2.add(z2), aa = a.multiply(a).mod(P);
            BigInteger b = x2.subtract(z2), bb = b.multiply(b).mod(P);
            BigInteger e = aa.subtract(bb);
            BigInteger c = x3.add(z3), d = x3.subtract(z3);
            BigInteger da = d.multiply(a).mod(P), cb = c.multiply(b).mod(P);
            BigInteger s = da.add(cb), m = da.subtract(cb);
            x3 = s.multiply(s).mod(P);
            z3 = x1.multiply(m.multiply(m)).mod(P);
            x2 = aa.multiply(bb).mod(P);
            z2 = e.multiply(aa.add(A24.multiply(e))).mod(P);
        }
        if (swap == 1) { x2 = x3; z2 = z3; }
        BigInteger r = x2.multiply(z2.modPow(P.subtract(BigInteger.valueOf(2)), P)).mod(P);
        byte[] be = r.toByteArray(), out = new byte[32];
        for (int i = 0; i < 32 && i < be.length; i++) out[i] = be[be.length - 1 - i];
        return out;
    }

    private static BigInteger le(byte[] b) {
        byte[] be = new byte[b.length + 1];
        for (int i = 0; i < b.length; i++) be[b.length - i] = b[i];
        return new BigInteger(be);
    }
}
