// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/**
 * @title  DeadMansKey V2
 * @notice Tek mirasçılı, çok tokenlu, ayarlanabilir süreli dijital miras sözleşmesi.
 */
contract DeadMansKey {

    address public owner;
    address public beneficiary;
    uint256 public lastPing;
    uint256 public timeout;
    bool    public fundsReleased;

    uint256 public constant MIN_ETH_FOR_GAS = 0.005 ether;
    uint256 public constant MIN_TIMEOUT =   7 days;
    uint256 public constant MAX_TIMEOUT = 365 days;

    address[] public tokenList;

    event Pinged(uint256 timestamp);
    event BeneficiaryUpdated(address newBeneficiary);
    event TimeoutUpdated(uint256 newTimeout);
    event ETHDeposited(uint256 amount);
    event TokenAdded(address token);
    event TokenRemoved(address token);
    event Released(address beneficiary, uint256 ethAmount);
    event TokenReleased(address token, uint256 amount);
    event EmergencyETHWithdrawn(uint256 amount);
    event EmergencyTokenWithdrawn(address token, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "DMK: Sadece sahip"); _; }
    modifier onlyBeneficiary() { require(msg.sender == beneficiary, "DMK: Sadece mirasci"); _; }
    modifier notReleased() { require(!fundsReleased, "DMK: Zaten serbest birakildi"); _; }
    modifier timeExpired() {
        require(block.timestamp >= lastPing + timeout, "DMK: Sure henuz dolmadi");
        _;
    }

    constructor(
        address _owner,
        address _beneficiary,
        uint256 _timeoutDays,
        address[] memory _tokens
    ) {
        require(_beneficiary != address(0), "DMK: Gecersiz mirasci");
        require(_beneficiary != _owner,     "DMK: Sahip mirasci olamaz");

        uint256 _timeout = _timeoutDays * 1 days;
        require(_timeout >= MIN_TIMEOUT, "DMK: En az 7 gun");
        require(_timeout <= MAX_TIMEOUT, "DMK: En fazla 365 gun");

        owner       = _owner;
        beneficiary = _beneficiary;
        timeout     = _timeout;
        lastPing    = block.timestamp;

        for (uint256 i = 0; i < _tokens.length; i++) {
            require(_tokens[i] != address(0), "DMK: Gecersiz token");
            tokenList.push(_tokens[i]);
            emit TokenAdded(_tokens[i]);
        }

        emit BeneficiaryUpdated(_beneficiary);
        emit Pinged(block.timestamp);
    }

    receive() external payable {
        require(msg.sender == owner, "DMK: Sadece sahip ETH gonderebilir");
        require(!fundsReleased, "DMK: Zaten serbest birakildi");
        emit ETHDeposited(msg.value);
    }

    function depositETH() external payable onlyOwner notReleased {
        require(msg.value > 0, "DMK: Sifir ETH");
        emit ETHDeposited(msg.value);
    }

    function ping() external onlyOwner notReleased {
        lastPing = block.timestamp;
        emit Pinged(block.timestamp);
    }

    function setBeneficiary(address _new) external onlyOwner notReleased {
        require(_new != address(0), "DMK: Gecersiz adres");
        require(_new != owner, "DMK: Sahip mirasci olamaz");
        beneficiary = _new;
        emit BeneficiaryUpdated(_new);
    }

    function setTimeout(uint256 _days) external onlyOwner notReleased {
        uint256 _timeout = _days * 1 days;
        require(_timeout >= MIN_TIMEOUT, "DMK: En az 7 gun");
        require(_timeout <= MAX_TIMEOUT, "DMK: En fazla 365 gun");
        timeout = _timeout;
        emit TimeoutUpdated(_timeout);
    }

    function addToken(address _token) external onlyOwner notReleased {
        require(_token != address(0), "DMK: Gecersiz token");
        for (uint256 i = 0; i < tokenList.length; i++) {
            require(tokenList[i] != _token, "DMK: Token zaten ekli");
        }
        tokenList.push(_token);
        emit TokenAdded(_token);
    }

    function removeToken(address _token) external onlyOwner notReleased {
        uint256 len = tokenList.length;
        for (uint256 i = 0; i < len; i++) {
            if (tokenList[i] == _token) {
                tokenList[i] = tokenList[len - 1];
                tokenList.pop();
                emit TokenRemoved(_token);
                return;
            }
        }
        revert("DMK: Token listede yok");
    }

    function releaseAll() external onlyBeneficiary notReleased timeExpired {
        require(address(this).balance >= MIN_ETH_FOR_GAS, "DMK: Gas icin en az 0.005 ETH gerekli");
        fundsReleased = true;

        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            (bool ok, ) = beneficiary.call{value: ethBal}("");
            require(ok, "DMK: ETH transferi basarisiz");
            emit Released(beneficiary, ethBal);
        }

        for (uint256 i = 0; i < tokenList.length; i++) {
            IERC20 token    = IERC20(tokenList[i]);
            uint256 allowed = token.allowance(owner, address(this));
            uint256 bal     = token.balanceOf(owner);
            uint256 amount  = allowed < bal ? allowed : bal;
            if (amount > 0) {
                bool ok = token.transferFrom(owner, beneficiary, amount);
                require(ok, "DMK: Token transferi basarisiz");
                emit TokenReleased(tokenList[i], amount);
            }
        }
    }

    function emergencyWithdrawETH() external onlyOwner notReleased {
        uint256 bal = address(this).balance;
        require(bal > 0, "DMK: ETH yok");
        (bool ok, ) = owner.call{value: bal}("");
        require(ok, "DMK: Transfer basarisiz");
        emit EmergencyETHWithdrawn(bal);
    }

    function emergencyWithdrawToken(address _token) external onlyOwner notReleased {
        IERC20 token = IERC20(_token);
        uint256 bal  = token.balanceOf(address(this));
        require(bal > 0, "DMK: Token bakiyesi yok");
        bool ok = token.transfer(owner, bal);
        require(ok, "DMK: Token transferi basarisiz");
        emit EmergencyTokenWithdrawn(_token, bal);
    }

    function timeRemaining() external view returns (uint256) {
        uint256 deadline = lastPing + timeout;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    function canRelease() external view returns (bool) {
        return (!fundsReleased && block.timestamp >= lastPing + timeout && address(this).balance >= MIN_ETH_FOR_GAS);
    }

    function getETHBalance() external view returns (uint256) { return address(this).balance; }
    function isGasSafe() external view returns (bool) { return address(this).balance >= MIN_ETH_FOR_GAS; }
    function getTokenList() external view returns (address[] memory) { return tokenList; }
    function getTokenAllowance(address _token) external view returns (uint256) {
        return IERC20(_token).allowance(owner, address(this));
    }
}

/**
 * @title  DeadMansKeyFactory
 * @notice Her kullanıcı için yeni bir DeadMansKey sözleşmesi deploy eder.
 *         Küçük bir deploy ücreti alır (0.002 ETH).
 */
contract DeadMansKeyFactory {

    // Base Mainnet default token adresleri
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address public constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    address public platformOwner;
    uint256 public deployFee = 0.002 ether;

    // Her kullanıcı adresinin deploy ettiği sözleşmeler
    mapping(address => address[]) public userContracts;
    // Tüm deploy edilen sözleşmeler
    address[] public allContracts;

    event ContractDeployed(
        address indexed owner,
        address indexed contractAddress,
        address beneficiary,
        uint256 timeoutDays
    );
    event FeeUpdated(uint256 newFee);
    event FeeWithdrawn(uint256 amount);

    modifier onlyPlatformOwner() {
        require(msg.sender == platformOwner, "Factory: Sadece platform sahibi");
        _;
    }

    constructor() {
        platformOwner = msg.sender;
    }

    /**
     * @notice Yeni bir DeadMansKey sözleşmesi deploy eder.
     * @param _beneficiary  Mirasçı adresi
     * @param _timeoutDays  Ping atılmadan geçebilecek gün sayısı (7-365)
     * @param _tokens       Ek token adresleri (boş bırakılabilir, varsayılan USDC/USDT/WBTC eklenir)
     */
    function deployContract(
        address _beneficiary,
        uint256 _timeoutDays,
        address[] calldata _tokens
    ) external payable returns (address) {
        require(msg.value >= deployFee, "Factory: Yetersiz deploy ucreti");
        require(_beneficiary != address(0), "Factory: Gecersiz mirasci");
        require(_beneficiary != msg.sender, "Factory: Sahip mirasci olamaz");

        // Varsayılan tokenları ekle
        address[] memory tokens = new address[](3 + _tokens.length);
        tokens[0] = USDC;
        tokens[1] = USDT;
        tokens[2] = WBTC;
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokens[3 + i] = _tokens[i];
        }

        DeadMansKey newContract = new DeadMansKey(
            msg.sender,
            _beneficiary,
            _timeoutDays,
            tokens
        );

        address contractAddr = address(newContract);
        userContracts[msg.sender].push(contractAddr);
        allContracts.push(contractAddr);

        emit ContractDeployed(msg.sender, contractAddr, _beneficiary, _timeoutDays);

        // Fazla ödemeyi iade et
        if (msg.value > deployFee) {
            (bool ok, ) = msg.sender.call{value: msg.value - deployFee}("");
            require(ok, "Factory: Iade basarisiz");
        }

        return contractAddr;
    }

    // ── PLATFORM YÖNETİMİ ────────────────────────────────

    function setDeployFee(uint256 _fee) external onlyPlatformOwner {
        require(_fee <= 0.1 ether, "Factory: Maksimum 0.1 ETH");
        deployFee = _fee;
        emit FeeUpdated(_fee);
    }

    function withdrawFees() external onlyPlatformOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "Factory: Bakiye yok");
        (bool ok, ) = platformOwner.call{value: bal}("");
        require(ok, "Factory: Transfer basarisiz");
        emit FeeWithdrawn(bal);
    }

    function transferPlatformOwnership(address _new) external onlyPlatformOwner {
        require(_new != address(0), "Factory: Gecersiz adres");
        platformOwner = _new;
    }

    // ── VIEW ──────────────────────────────────────────────

    function getUserContracts(address _user) external view returns (address[] memory) {
        return userContracts[_user];
    }

    function getAllContracts() external view returns (address[] memory) {
        return allContracts;
    }

    function getTotalDeployments() external view returns (uint256) {
        return allContracts.length;
    }
}