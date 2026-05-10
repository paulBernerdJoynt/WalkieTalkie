public class BlobUtils {
    /**
     * Concatenates two Blobs. Apex has no native blob concat; base64 strings can only
     * be directly concatenated when the first blob's byte count is a multiple of 3
     * (otherwise the base64 padding chars land in the middle and corrupt decoding).
     * When not aligned, we use hex to extract and re-encode the boundary bytes.
     */
    public static Blob concat(Blob b1, Blob b2) {
        Integer mod = Math.mod(b1.size(), 3);
        if (mod == 0) {
            return EncodingUtil.base64Decode(
                EncodingUtil.base64Encode(b1) + EncodingUtil.base64Encode(b2)
            );
        }

        String hex1     = EncodingUtil.convertToHex(b1);
        String hex2     = EncodingUtil.convertToHex(b2);
        Integer tailLen = mod * 2;
        Integer headLen = (3 - mod) * 2;

        String mainHex   = hex1.left(hex1.length() - tailLen);
        String bridgeHex = hex1.right(tailLen) + hex2.left(headLen);
        String restHex   = hex2.length() > headLen ? hex2.substring(headLen) : '';

        // mainHex decodes to a multiple-of-3 byte count — no padding in its base64
        // bridgeHex decodes to exactly 3 bytes — no padding
        // Safe to concatenate all three base64 segments
        String result = '';
        if (mainHex.length() > 0) {
            result += EncodingUtil.base64Encode(EncodingUtil.convertFromHex(mainHex));
        }
        result += EncodingUtil.base64Encode(EncodingUtil.convertFromHex(bridgeHex));
        if (restHex.length() > 0) {
            result += EncodingUtil.base64Encode(EncodingUtil.convertFromHex(restHex));
        }
        return EncodingUtil.base64Decode(result);
    }
}
