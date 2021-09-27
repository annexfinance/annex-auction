const {BigNumber} = require("ethers");


// encoding

 var bytes =     "0x" +
      BigNumber.from(1n).toHexString().slice(2).padStart(16, "0") +
      BigNumber.from(20000000n).toHexString().slice(2).padStart(24, "0") +
      BigNumber.from(10000000000000000000n).toHexString().slice(2).padStart(24, "0")

      console.log(bytes);

// decoding
// var order_bytes = "0x00000000000000010000000AD78EBC5AC6200000000000000000000001312D00";
var order_bytes = "0x00000000000000010000000ad78ebc5ac620000000000001158e460913d00000";
console.log(
     {
          userId: BigNumber.from("0x" + order_bytes.substring(2, 18)).toString(),
          buyAmount: BigNumber.from("0x" + order_bytes.substring(19, 42)).toString(),
          sellAmount: BigNumber.from("0x" + order_bytes.substring(43, 66)).toString(),
        }
);