# Same as TransactionBuilder but outputs a transaction hash with all the
# required data to create and sign a transaction using a BitcoinTrezor.
class Pochette::TrezorTransactionBuilder < Pochette::TransactionBuilder

  Contract ({
    :bip32_addresses => C::ArrayOf[C::Or[
      [C::Or[String, C::ArrayOf[String]], C::ArrayOf[Integer]],
      [C::Or[String, C::ArrayOf[String]], C::ArrayOf[Integer], C::Maybe[Integer]]
    ]],
    :outputs => C::Maybe[C::ArrayOf[[String, C::Num]]],
    :utxo_blacklist => C::Maybe[C::ArrayOf[[String, Integer]]],
    :change_address => C::Maybe[String],
    :fee_per_kb => C::Maybe[C::Num],
    :spend_all => C::Maybe[C::Bool],
  }) => C::Any
  def initialize(options)
    options = options.dup
    initialize_bip32_addresses(options)
    super(options)
    return unless valid?
    build_trezor_inputs
    build_trezor_outputs
    build_transactions
  end

  Contract C::None => C::Maybe[({
    :input_total => C::Num,
    :output_total => C::Num,
    :fee => C::Num,
    :outputs => C::ArrayOf[[String, C::Num]],
    :inputs => C::ArrayOf[[String, String, Integer, C::Num, String]],
    :utxos_to_blacklist => C::ArrayOf[[String, Integer]],
    :transactions => C::ArrayOf[Hash],
    :trezor_inputs => C::ArrayOf[{
      address_n: C::ArrayOf[Integer],
      prev_hash: String,
      prev_index: Integer,
      script_type: C::Maybe[C::Any],
      multisig: C::Maybe[C::Any],
    }],
    :trezor_outputs => C::ArrayOf[{
      script_type: String,
      address: String,
      amount: C::Num
    }]
  })]
  def as_hash
    return nil unless valid?
    super.merge(
      trezor_inputs: trezor_inputs,
      trezor_outputs: trezor_outputs,
      transactions: transactions)
  end

protected
  attr_accessor :trezor_outputs
  attr_accessor :trezor_inputs
  attr_accessor :transactions
  attr_accessor :bip32_address_lookup

  def initialize_bip32_addresses(options)
    if options[:bip32_addresses].blank?
      self.errors = [:no_bip32_addresses_given]
      return
    end
    options[:addresses] = options[:bip32_addresses].collect{|a| address_from_bip32(a) }
    self.bip32_address_lookup = options[:bip32_addresses].reduce({}) do |accum, addr|
      accum[address_from_bip32(addr)] = addr
      accum
    end
  end

  # Bip32 addresses may look like an address with a bip32 path, or
  # an array of xpubs, bip32 path and M (as in M of N) for multisig p2sh addresses.
  def address_from_bip32(array)
    if array.first.is_a?(String)
      array.first
    else
      public_keys = array.first.collect do |x|
        MoneyTree::Node.from_bip32(x).node_for_path(array[1].join('/')).public_key.key
      end
      address, _ = Bitcoin.pubkeys_to_p2sh_multisig_address(array.last, *public_keys)
      address
    end
  end

  def build_trezor_inputs
    self.trezor_inputs = inputs.collect do |input|
      address = bip32_address_lookup[input[0]]
      hash = { address_n: address[1],
        prev_hash: input[1], prev_index: input[2] }
      if address.size == 3
        xpubs = address.first
        m = address.last
        hash[:script_type] = 'SPENDMULTISIG'
        hash[:multisig] = {
          signatures: [''] * xpubs.size,
          m: m,
          pubkeys: xpubs.collect do |xpub|
            node = MoneyTree::Node.from_bip32(xpub)
            { address_n: address[1],
              node: {
                chain_code: node.chain_code.to_s(16),
                depth: 0, 
                child_num: 0, 
                fingerprint: 0,
                public_key: node.public_key.key,
              }
            }
          end
        }
      end
      hash
    end
  end

  def build_trezor_outputs
    self.trezor_outputs = outputs.collect do |address, amount|
      type = Bitcoin.address_type(address) == :hash160 ? 'PAYTOADDRESS' : 'PAYTOSCRIPTHASH'
      { script_type: type, address: address, amount: amount.to_i }
    end
  end

  def build_transactions
    txids = inputs.collect{|i| i[1] }
    self.transactions = backend.list_transactions(txids)
  end
end
