// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IExecutableProposal.sol";
import "./VotingToken.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract QuadraticVoting {
    // =========================================================================
    //                              TIPOS
    // =========================================================================

    enum ProposalStatus { Pending, Approved, Cancelled }

    struct Proposal {
        string title;
        string description;
        uint budget; // Wei. 0 = propuesta de signaling
        address proposalAddress; // Contrato que implementa IExecutableProposal
        address creator; // Participante que creó la propuesta
        ProposalStatus status;
        uint totalVotes; // Suma de votos recibidos
        uint totalTokensStaked; // Suma de tokens bloqueados (coste cuadrático)
        uint arrayIndex; // Índice en su array de la ronda (swap-and-pop)
        uint votingRound; // Ronda en la que se creó la propuesta
        bool signalingExecuted; // Solo signaling: evita doble ejecución (pull)
        mapping(address => uint) voterVotes; // Votos depositados por votante
    }

    // =========================================================================
    //                          ESTADO
    // =========================================================================

    address public owner;

    VotingToken public votingToken;

    uint public tokenPrice;

    bool public votingOpen;

    // Presupuesto total disponible para financiar propuestas
    uint public totalBudget;

    // Número de participantes activos inscritos
    uint public participantCount;

    // Contador global de IDs de propuestas (nunca se resetea entre rondas
    // para evitar colisiones de IDs y datos stale en mappings)
    uint public proposalCount;

    // Ronda de votación actual (se incrementa en openVoting)
    uint public currentVotingRound;

    // Registro de participantes activos
    mapping(address => bool) public participants;

    // Almacén de propuestas por ID
    mapping(uint => Proposal) internal proposals;

    // Arrays de propuestas por ronda
    mapping(uint => uint[]) internal pendingFinancingIds;
    mapping(uint => uint[]) internal approvedProposalIds; 
    mapping(uint => uint[]) internal signalingProposalIds; 

    // Indica si el periodo de votación de una ronda ya fue cerrado
    mapping(uint => bool) public roundClosed;

    // =========================================================================
    //                           MODIFICADORES
    // =========================================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Solo el owner");
        _;
    }

    modifier onlyParticipant() {
        require(participants[msg.sender], "No es participante");
        _;
    }

    modifier onlyVotingOpen() {
        require(votingOpen, "La votacion no esta abierta");
        _;
    }

    modifier onlyVotingClosed() {
        require(!votingOpen, "La votacion ya esta abierta");
        _;
    }

    // =========================================================================
    //                           CONSTRUCTOR
    // =========================================================================

    constructor(uint _tokenPrice, uint _maxTokenSupply) {
        require(_tokenPrice > 0, "Precio debe ser > 0");
        require(_maxTokenSupply > 0, "Max supply debe ser > 0");

        owner = msg.sender;
        tokenPrice = _tokenPrice;
        votingToken = new VotingToken(_maxTokenSupply);
    }

    // =========================================================================
    //                    GESTIÓN DEL PERIODO DE VOTACIÓN
    // =========================================================================

    // Abre un nuevo periodo de votación con un presupuesto inicial.
    // Solo el owner puede abrir la votación. El msg.value es el presupuesto inicial para financiar propuestas.
    function openVoting() external payable onlyOwner onlyVotingClosed {
        require(msg.value > 0, "Debe aportar presupuesto inicial");

        votingOpen = true;
        currentVotingRound++;
        totalBudget = msg.value;
    }

    // Cierre del periodo de votación. Pull-over-push: O(1).
    // No itera sobre propuestas ni votantes; los participantes reclamarán
    // sus tokens con claimRefund y dispararán las propuestas de signaling
    // con executeSignaling.
    function closeVoting() external onlyOwner onlyVotingOpen {
        votingOpen = false;
        roundClosed[currentVotingRound] = true;

        uint remainingBudget = totalBudget;
        totalBudget = 0;

        // Transferir presupuesto restante al owner (CEI: estado actualizado antes)
        if (remainingBudget > 0) {
            (bool ok, ) = owner.call{value: remainingBudget}("");
            require(ok, "Fallo al transferir presupuesto");
        }
    }

    // =========================================================================
    //                      GESTIÓN DE PARTICIPANTES
    // =========================================================================

    // Inscribe al llamante como participante. 
    // Se puede inscribir en cualquier momento (antes o durante la votación). 
    // Debe enviar ETH suficiente para comprar al menos 1 token. **El cambio sobrante se devuelve.**
    function addParticipant() external payable {
        require(!participants[msg.sender], "Ya es participante");

        participants[msg.sender] = true;
        participantCount++;

        _buyTokens(msg.sender, msg.value);
    }

    // Elimina al llamante como participante. 
    // No podrá depositar votos, crear propuestas ni comprar/vender tokens hasta que se vuelva a inscribir.
    // Sus tokens y votos depositados se conservan (puede reclamarlos vía claimRefund tras el cierre).
    function removeParticipant() external onlyParticipant {
        participants[msg.sender] = false;
        participantCount--;
    }

    // =========================================================================
    //                      OPERACIONES CON TOKENS
    // =========================================================================

    // Permite a un participante inscrito comprar más tokens.
    // El cambio sobrante se devuelve.
    function buyTokens() external payable onlyParticipant {
        _buyTokens(msg.sender, msg.value);

    }

    // Permite a un participante devolver tokens no utilizados y recuperar el ETH
    function sellTokens(uint numTokens) external onlyParticipant {
        require(numTokens > 0, "Debe vender al menos 1 token");
        require(votingToken.balanceOf(msg.sender) >= numTokens, "Tokens insuficientes");

        votingToken.burn(msg.sender, numTokens);

        uint ethToReturn = numTokens * tokenPrice;

        (bool ok, ) = msg.sender.call{value: ethToReturn}("");
        require(ok, "Fallo al transferir ETH");
    }

    // Devuelve la dirección del contrato ERC20 del sistema.
    // Los participantes pueden usarla para operar con sus tokens (approve, transfer, etc.)
    function getERC20() external view returns (address) {
        return address(votingToken);
    }

    // =========================================================================
    //                      GESTIÓN DE PROPUESTAS
    // =========================================================================

    // Crea una nueva propuesta. Solo participantes con votación abierta.
    function addProposal(string calldata _title, string calldata _description, uint _budget, address _proposalAddr)
        external onlyParticipant onlyVotingOpen
        returns (uint)
    {
        require(_proposalAddr != address(0), "Direccion de propuesta invalida");
        require(IERC165(_proposalAddr).supportsInterface(type(IExecutableProposal).interfaceId), "No implementa IExecutableProposal");

        uint proposalId = proposalCount++;

        Proposal storage p = proposals[proposalId];
        p.title = _title;
        p.description = _description;
        p.budget = _budget;
        p.proposalAddress = _proposalAddr;
        p.creator = msg.sender;
        p.status = ProposalStatus.Pending;
        p.votingRound = currentVotingRound;

        if (_budget == 0) {
            // Propuesta de signaling
            uint[] storage arr = signalingProposalIds[currentVotingRound];
            p.arrayIndex = arr.length;
            arr.push(proposalId);
        } else {
            // Propuesta de financiación
            uint[] storage arr = pendingFinancingIds[currentVotingRound];
            p.arrayIndex = arr.length;
            arr.push(proposalId);
        }

        return proposalId;
    }

    // Cancela una propuesta pendiente. Solo el creador puede cancelar.
    // Pull-over-push: NO devuelve tokens; los votantes reclaman con claimRefund.
    // Coste O(1).
    function cancelProposal(uint proposalId) external onlyVotingOpen {
        Proposal storage p = proposals[proposalId];

        require(p.votingRound == currentVotingRound, "Propuesta no es de la ronda actual");
        require(msg.sender == p.creator, "Solo el creador puede cancelar");
        require(p.status == ProposalStatus.Pending, "La propuesta no esta pendiente");

        p.status = ProposalStatus.Cancelled;

        if (p.budget == 0) {
            _removeFromArray(signalingProposalIds[currentVotingRound], p.arrayIndex);
        } else {
            _removeFromArray(pendingFinancingIds[currentVotingRound], p.arrayIndex);
        }
    }

    // =========================================================================
    //                       CONSULTAS DE PROPUESTAS
    // =========================================================================

    function getPendingProposals() external view onlyVotingOpen returns (uint[] memory) {
        return pendingFinancingIds[currentVotingRound];
    }

    function getApprovedProposals() external view onlyVotingOpen returns (uint[] memory) {
        return approvedProposalIds[currentVotingRound];
    }

    function getSignalingProposals() external view onlyVotingOpen returns (uint[] memory) {
        return signalingProposalIds[currentVotingRound];
    }

    function getProposalInfo(uint proposalId) external view onlyVotingOpen returns (
            string memory title,
            string memory description,
            uint budget,
            uint totalVotes,
            ProposalStatus status,
            address proposalAddress,
            address creator
        )
    {
        Proposal storage p = proposals[proposalId];
        require(p.votingRound == currentVotingRound, "Propuesta no es de la ronda actual");

        return (
            p.title,
            p.description,
            p.budget,
            p.totalVotes,
            p.status,
            p.proposalAddress,
            p.creator
        );
    }

    // =========================================================================
    //                            VOTACIÓN
    // =========================================================================

    // Deposita votos sobre una propuesta. Coste cuadrático sobre el total acumulado del votante.
    function stake(uint proposalId, uint numVotes) external onlyParticipant onlyVotingOpen {
        require(numVotes > 0, "Debe depositar al menos 1 voto");

        Proposal storage p = proposals[proposalId];

        require(p.votingRound == currentVotingRound, "Propuesta no es de la ronda actual");
        require(p.status == ProposalStatus.Pending, "La propuesta no esta pendiente");

        // Coste cuadrático
        uint prevVotes = p.voterVotes[msg.sender];
        uint newTotal = prevVotes + numVotes;
        uint tokenCost = (newTotal * newTotal) - (prevVotes * prevVotes);

        votingToken.transferFrom(msg.sender, address(this), tokenCost);

        p.voterVotes[msg.sender] = newTotal;
        p.totalVotes += numVotes;
        p.totalTokensStaked += tokenCost;

        // Si es propuesta de financiación, comprobar si debe aprobarse
        if (p.budget > 0) {
            _checkAndExecuteProposal(proposalId);
        }
    }

    // Retira votos depositados por el llamante en una propuesta pendiente.
    // Devuelve los tokens correspondientes al coste cuadrático
    function withdrawFromProposal(uint proposalId, uint numVotes) external onlyParticipant onlyVotingOpen {
        require(numVotes > 0, "Debe retirar al menos 1 voto");

        Proposal storage p = proposals[proposalId];

        require(p.votingRound == currentVotingRound, "Propuesta no es de la ronda actual");
        require(p.status == ProposalStatus.Pending, "La propuesta no esta pendiente");

        uint currentVotes = p.voterVotes[msg.sender];
        require(numVotes <= currentVotes, "Votos insuficientes para retirar");

        // Reembolso cuadrático
        uint remaining = currentVotes - numVotes;
        uint tokensToReturn = (currentVotes * currentVotes) - (remaining * remaining);

        votingToken.transfer(msg.sender, tokensToReturn);

        p.voterVotes[msg.sender] = remaining;
        p.totalVotes -= numVotes;
        p.totalTokensStaked -= tokensToReturn;
    }

    // =========================================================================
    //                        PULL-OVER-PUSH
    // =========================================================================

    // Reclama los tokens de votos depositados en una propuesta
    // - Propuestas canceladas: cualquier ronda
    // - Propuestas pendientes: rondas cerradas
    // Coste O(1).
    function claimRefund(uint proposalId) external {
        Proposal storage p = proposals[proposalId];

        uint votes = p.voterVotes[msg.sender];
        require(votes > 0, "Sin votos a reclamar");

        bool refundable = (p.status == ProposalStatus.Cancelled) ||
                          (roundClosed[p.votingRound] && p.status == ProposalStatus.Pending);
        require(refundable, "Propuesta no reembolsable");

        uint tokensToReturn = votes * votes;

        p.voterVotes[msg.sender] = 0;

        p.totalVotes -= votes;
        p.totalTokensStaked -= tokensToReturn;

        votingToken.transfer(msg.sender, tokensToReturn);
    }

    // Dispara la ejecución de una propuesta de signaling de una ronda ya cerrada.
    function executeSignaling(uint proposalId) external {
        Proposal storage p = proposals[proposalId];

        require(p.budget == 0, "No es propuesta de signaling");
        require(roundClosed[p.votingRound], "La ronda aun esta abierta");
        require(p.status == ProposalStatus.Pending, "Propuesta cancelada");
        require(!p.signalingExecuted, "Ya ejecutada");

        // Effect antes de Interaction (CEI) para impedir reentradas
        p.signalingExecuted = true;

        IExecutableProposal(p.proposalAddress).executeProposal{
            value: 0,
            gas: 100000
        }(proposalId, p.totalVotes, p.totalTokensStaked);
    }

    // =========================================================================
    //                       FUNCIONES INTERNAS
    // =========================================================================

    // Comprueba si una propuesta de financiación cumple las condiciones de aprobación y, si es así, la ejecuta.
    // Condiciones: (1) presupuesto suficiente, (2) votos > umbral.
    function _checkAndExecuteProposal(uint proposalId) internal {
        Proposal storage p = proposals[proposalId];

        // Condición 1: presupuesto total suficiente para financiar la propuesta
        if (totalBudget < p.budget) return;

        // Condición 2: votos superan el umbral.
        // threshold_i = (0.2 + budget_i/totalBudget) * numParticipants + numPendingProposals
        // Reescribimos sin divisiones multiplicando ambos lados por (5 * totalBudget):
        // totalVotes_i * 5 * totalBudget > (totalBudget + 5 * budget_i) * numParticipants + numPendingProposals * 5 * totalBudget

        uint left = p.totalVotes * 5 * totalBudget;
        uint right = (totalBudget + 5 * p.budget) * participantCount + pendingFinancingIds[currentVotingRound].length * 5 * totalBudget;

        if (left <= right) return;

        // PROPUESTA APROBADA

        // Actualizar presupuesto: sumar valor en wei de los tokens consumidos, restar coste de la propuesta
        uint tokenValue = p.totalTokensStaked * tokenPrice;
        totalBudget = totalBudget + tokenValue - p.budget;

        p.status = ProposalStatus.Approved;

        // Mover de pendientes a aprobadas (swap-and-pop, O(1))
        _removeFromArray(pendingFinancingIds[currentVotingRound], p.arrayIndex);
        uint[] storage approved = approvedProposalIds[currentVotingRound];
        p.arrayIndex = approved.length;
        approved.push(proposalId);

        // Quemar los tokens consumidos por la aprobación
        votingToken.burn(address(this), p.totalTokensStaked);

        uint executionBudget = p.budget;
        uint executionVotes = p.totalVotes;
        uint executionTokens = p.totalTokensStaked;
        address executionAddr = p.proposalAddress;

        IExecutableProposal(executionAddr).executeProposal{
            value: executionBudget,
            gas: 100000
        }(proposalId, executionVotes, executionTokens);
    }

    // Elimina un elemento de un array de IDs usando swap-and-pop.
    // Actualiza el arrayIndex de la propuesta movida. Coste O(1).
    function _removeFromArray(uint[] storage arr, uint index) internal {
        uint lastIndex = arr.length - 1;

        if (index != lastIndex) {
            uint lastId = arr[lastIndex];
            arr[index] = lastId;
            proposals[lastId].arrayIndex = index;
        }

        arr.pop();
    }

    function _buyTokens(address sender, uint ethSent) internal {
        require(ethSent >= tokenPrice, "ETH insuficiente para 1 token");

        uint numTokens = ethSent / tokenPrice;
        uint change = ethSent - (numTokens * tokenPrice);

        votingToken.mint(sender, numTokens);
        
        if (change > 0) {
            (bool ok, ) = sender.call{value: change}("");
            require(ok, "Fallo al devolver cambio");
        }
    }
}
