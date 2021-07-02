const {BigNumber} = require("ethers");


// encoding

 var bytes =     "0x" +
      BigNumber.from(2n).toHexString().slice(2).padStart(16, "0") +
      BigNumber.from(1000000000000000000n).toHexString().slice(2).padStart(24, "0") +
      BigNumber.from(2400000000000000000n).toHexString().slice(2).padStart(24, "0")

      console.log(bytes);

// decoding
var order_bytes = "0x0000000000000000000000008ac7230489e8000000000000b893178898b20000";
console.log(
     {
          userId: BigNumber.from("0x" + order_bytes.substring(2, 18)).toString(),
          sellAmount: BigNumber.from("0x" + order_bytes.substring(43, 66)).toString(),
          buyAmount: BigNumber.from("0x" + order_bytes.substring(19, 42)).toString(),
        }
);