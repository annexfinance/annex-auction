const {BigNumber} = require("ethers");


// encoding

 var bytes =     "0x" +
      BigNumber.from(2n).toHexString().slice(2).padStart(16, "0") +
      BigNumber.from(4000000000000000000n).toHexString().slice(2).padStart(24, "0") +
      BigNumber.from(9200000000000000000n).toHexString().slice(2).padStart(24, "0")

      console.log(bytes);

// decoding
var order_bytes = "0x000000000000000100000000094079cd1a42aaaa00000000094079cd1a42aaab";
console.log(
     {
          userId: BigNumber.from("0x" + order_bytes.substring(2, 18)).toString(),
          sellAmount: BigNumber.from("0x" + order_bytes.substring(43, 66)).toString(),
          buyAmount: BigNumber.from("0x" + order_bytes.substring(19, 42)).toString(),
        }
);