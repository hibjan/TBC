// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IExecutableProposal {
    function executeProposal(
        uint proposalId,
        uint numVotes, //Votos totales recibidos en la propuesta
        uint numTokens //Tokens totales depositados en la propuesta
    ) external payable;
}
