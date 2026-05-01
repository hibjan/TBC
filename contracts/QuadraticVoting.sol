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
        uint totalTokensStaked; // Suma de tokens bloqueados (coste cuadrático acumulado)
        uint arrayIndex; // Índice en su array correspondiente (swap-and-pop)
        uint votingRound; // Ronda en la que se creó la propuesta
        address[] voters; // Lista de votantes (para iterar en devoluciones)
        mapping(address => uint) voterVotes; // Votos depositados por cada votante
        mapping(address => bool) hasVoted; // Controla duplicados en voters[]
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

    // IDs de propuestas de financiación pendientes de aprobar
    uint[] internal pendingFinancingIds;

    // IDs de propuestas de financiación aprobadas
    uint[] internal approvedProposalIds;

    // IDs de propuestas de signaling (presupuesto = 0)
    uint[] internal signalingProposalIds;

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

        // Limpiar arrays de la ronda anterior
        delete pendingFinancingIds;
        delete approvedProposalIds;
        delete signalingProposalIds;
    }

    // Cierra el periodo de votación. 
    //  - Ejecuta las propuestas de signaling
    //  - Devuelve tokens de propuestas no aprobadas
    //  - Transfiere el presupuesto restante al owner.
    function closeVoting() external onlyOwner onlyVotingOpen {
        
        votingOpen = false;

        // 1. Propuestas de financiación pendientes: descartar y devolver tokens
        for (uint i = 0; i < pendingFinancingIds.length; i++) {
            _returnTokensToVoters(pendingFinancingIds[i]);
        }

        // 2. Propuestas de signaling: ejecutar y devolver tokens
        for (uint i = 0; i < signalingProposalIds.length; i++) {
            uint pid = signalingProposalIds[i];
            Proposal storage p = proposals[pid];

            IExecutableProposal(p.proposalAddress).executeProposal{
                value: 0,
                gas: 100000
            }(pid, p.totalVotes, p.totalTokensStaked);

            // Devolver tokens a votantes
            _returnTokensToVoters(pid);
        }

        // 3. Guardar presupuesto restante y limpiar estado
        uint remainingBudget = totalBudget;
        totalBudget = 0;

        delete pendingFinancingIds;
        delete approvedProposalIds;
        delete signalingProposalIds;

        // 4. Transferir presupuesto restante al owner (última acción, CEI)
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
        // Checks
        require(!participants[msg.sender], "Ya es participante");
        require(msg.value >= tokenPrice, "Debe comprar al menos 1 token");

        uint numTokens = msg.value / tokenPrice;
        uint change = msg.value - (numTokens * tokenPrice);

        // Effects: registrar participante y acuñar tokens
        participants[msg.sender] = true;
        participantCount++;

        votingToken.mint(msg.sender, numTokens);

        // Interactions: devolver cambio si lo hay
        if (change > 0) {
            (bool ok, ) = msg.sender.call{value: change}("");
            require(ok, "Fallo al devolver cambio");
        }
    }

    // Elimina al llamante como participante. 
    // No podrá depositar votos, crear propuestas ni comprar/vender tokens hasta que se vuelva a inscribir.
    // Sus votos depositados permanecen vigentes y sus tokens se conservan.
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
        require(msg.value >= tokenPrice, "ETH insuficiente para 1 token");

        uint numTokens = msg.value / tokenPrice;
        uint change = msg.value - (numTokens * tokenPrice);

        votingToken.mint(msg.sender, numTokens);

        if (change > 0) {
            (bool ok, ) = msg.sender.call{value: change}("");
            require(ok, "Fallo al devolver cambio");
        }
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
    // _title: Título de la propuesta
    // _description: Descripción de la propuesta
    // _budget: Presupuesto en Wei (0 para signaling)
    // _proposalAddr: Dirección del contrato que implementa IExecutableProposal
    // Retorna: proposalId - Identificador de la propuesta creada
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
            p.arrayIndex = signalingProposalIds.length;
            signalingProposalIds.push(proposalId);
        } 
        else {
            // Propuesta de financiación
            p.arrayIndex = pendingFinancingIds.length;
            pendingFinancingIds.push(proposalId);
        }

        return proposalId;
    }

    // Cancela una propuesta pendiente. Solo el creador puede cancelar.
    // Los tokens depositados en la propuesta se devuelven a sus votantes.
    function cancelProposal(uint proposalId) external onlyVotingOpen {
        Proposal storage p = proposals[proposalId];

        require(p.votingRound == currentVotingRound, "Propuesta no es de la ronda actual");
        require(msg.sender == p.creator, "Solo el creador puede cancelar");
        require(p.status == ProposalStatus.Pending, "La propuesta no esta pendiente");

        p.status = ProposalStatus.Cancelled;

        if (p.budget == 0) {
            _removeFromArray(signalingProposalIds, p.arrayIndex);
        } 
        else {
            _removeFromArray(pendingFinancingIds, p.arrayIndex);
        }

        _returnTokensToVoters(proposalId);
    }

    // =========================================================================
    //                       CONSULTAS DE PROPUESTAS
    // =========================================================================

    // Devuelve los IDs de las propuestas de financiación pendientes.
    function getPendingProposals() external view onlyVotingOpen returns (uint[] memory){
        return pendingFinancingIds;
    }

    // Devuelve los IDs de las propuestas aprobadas.
    function getApprovedProposals() external view onlyVotingOpen returns (uint[] memory){
        return approvedProposalIds;
    }

    // Devuelve los IDs de las propuestas de signaling.
    function getSignalingProposals() external view onlyVotingOpen returns (uint[] memory){
        return signalingProposalIds;
    }

    // Devuelve los datos de una propuesta de la ronda actual.
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

    // Deposita votos sobre una propuesta. 
    // El coste en tokens es cuadrático respecto al total de votos del votante en esa propuesta.
    // **Requiere que el votante haya cedido (approve) los tokens necesarios al contrato QuadraticVoting previamente.**
    // El coste de pasar de prevVotes a (prevVotes + numVotes) votos es: (prevVotes + numVotes)² - prevVotes²
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

        // Registrar votante si es su primer voto en esta propuesta
        if (!p.hasVoted[msg.sender]) {
            p.voters.push(msg.sender);
            p.hasVoted[msg.sender] = true;
        }

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

        p.voterVotes[msg.sender] = remaining;
        p.totalVotes -= numVotes;
        p.totalTokensStaked -= tokensToReturn;

        votingToken.transfer(msg.sender, tokensToReturn);
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

        // Condición 2: votos superan el umbral (totalVotes_i > threshold_i)

        // Para lidiar con divisiones, escalamos con denominador

        // threshold_i = (0.2 + budget_i/totalBudget) * numParticipants + numPendingProposals
        // threshold_i = (1/5 + budget_i/totalBudget) * numParticipants + numPendingProposals
        // threshold_i = ((totalBudget + 5 * budget_i) / (5 * totalBudget)) * numParticipants + numPendingProposals

        // threshold_i * (5 * totalBudget) = (totalBudget + 5 * budget_i) * numParticipants + numPendingProposals * 5 * totalBudget

        // totalVotes_i > threshold_i
        // totalVotes_i * (5 * totalBudget) > threshold_i * (5 * totalBudget)
        // totalVotes_i * (5 * totalBudget) > (totalBudget + 5 * budget_i) * numParticipants + numPendingProposals * 5 * totalBudget
    
        uint left = p.totalVotes * 5 * totalBudget;
        uint right = (totalBudget + 5 * p.budget) * participantCount + pendingFinancingIds.length * 5 * totalBudget;

        if (left <= right) return;

        // PROPUESTA APROBADA

        // Actualizar presupuesto: sumar valor de tokens consumidos, restar presupuesto de la propuesta
        uint tokenValue = p.totalTokensStaked * tokenPrice;
        totalBudget = totalBudget + tokenValue - p.budget;

        p.status = ProposalStatus.Approved;

        // Mover de pendingFinancingIds a approvedProposalIds (swap-and-pop)
        _removeFromArray(pendingFinancingIds, p.arrayIndex);
        p.arrayIndex = approvedProposalIds.length;
        approvedProposalIds.push(proposalId);

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

    // Devuelve los tokens bloqueados a todos los votantes de una propuesta.
    // El coste de n votos es n² tokens, por lo que se devuelve voterVotes[v]² tokens a cada votante v.
    function _returnTokensToVoters(uint proposalId) internal {
        Proposal storage p = proposals[proposalId];

        for (uint i = 0; i < p.voters.length; i++) {
            address voter = p.voters[i];
            uint votes = p.voterVotes[voter];

            if (votes > 0) {
                uint tokens = votes * votes;
                p.voterVotes[voter] = 0;
                votingToken.transfer(voter, tokens);
            }
        }

        p.totalVotes = 0;
        p.totalTokensStaked = 0;
    }

    // Elimina un elemento de un array de IDs usando swap-and-pop.
    // Actualiza el arrayIndex de la propuesta que se mueve al hueco.
    // Coste: O(1).
    // arr: Array de IDs (storage reference)
    // index: Índice del elemento a eliminar
    function _removeFromArray(uint[] storage arr, uint index) internal {
        uint lastIdx = arr.length - 1;

        if (index != lastIdx) {
            uint lastId = arr[lastIdx];
            arr[index] = lastId;
            proposals[lastId].arrayIndex = index;
        }

        arr.pop();
    }
}
