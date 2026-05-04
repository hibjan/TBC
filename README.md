# Quadratic Voting System (TBC)

## Descripción del Proyecto

Este proyecto implementa un sistema de votación cuadrática en la blockchain de Ethereum utilizando contratos inteligentes escritos en Solidity. El sistema permite crear propuestas, votar sobre ellas con un mecanismo cuadrático donde el costo de los votos aumenta cuadráticamente con la cantidad, y ejecutar propuestas aprobadas. Incluye un token ERC-20 para gestionar los derechos de voto y contratos para propuestas ejecutables y de prueba.

Para más detalles técnicos y decisiones de diseño, consulta el archivo [memoria.pdf](memoria.pdf) y [requirements_ES.pdf](requirements_ES.pdf).

## Estructura del Proyecto

El proyecto se divide en dos carpetas principales: `contracts/` y `misc/`. La carpeta `contracts/` alberga todos los contratos inteligentes desarrollados en Solidity. Incluye `QuadraticVoting.sol`, que implementa el núcleo del sistema de votación cuadrática; `VotingToken.sol`, un token ERC-20 para gestionar los derechos de voto; `IExecutableProposal.sol`, una interfaz para propuestas que pueden ejecutarse automáticamente; `TestProposal.sol`, un contrato de prueba utilizado para validar la funcionalidad; y `QuadraticVotingOLD.sol`, una versión anterior del contrato para referencia.

La carpeta `misc/` contiene herramientas auxiliares y archivos de configuración. Aquí se encuentra `decode_log.py`, un script en Python para decodificar logs de eventos de la blockchain; `abi.json`, el Application Binary Interface de los contratos; `log.json`, un archivo con logs de transacciones; y `requirements.txt`, que detalla las dependencias necesarias para ejecutar el script.

## Uso de decode_log.py

El script `decode_log.py` se utiliza para decodificar y analizar los logs de eventos generados por las transacciones en la blockchain. Específicamente, se emplea para interpretar los eventos emitidos por el contrato `TestProposal.sol`, como los eventos de prueba que registran el resultado de las votaciones o la ejecución de propuestas. Para ejecutar el script, instala las dependencias listadas en `requirements.txt`, es decir, ejecuta:

```bash
cd misc
pip install -r requirements.txt
python decode_log.py abi.json log.json
```

Esto permite visualizar de manera legible los datos de los eventos, facilitando la depuración y el análisis del comportamiento del sistema de votación.
