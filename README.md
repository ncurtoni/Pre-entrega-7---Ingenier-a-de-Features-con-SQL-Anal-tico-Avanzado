# Ingenieria de Features con SQL Analitico Avanzado

Script que transforma datos crudos de pedidos de e-commerce (tablas `usuarios`
y `pedidos`) en un dataset de features por usuario, listo para entrenar un
modelo de prediccion de abandono (churn).

## Archivo

- `features.sql`: esquema, datos de partida, y la consulta final que genera
  las features. Ejecutable de punta a punta en DuckDB.

## Como ejecutarlo

```bash
duckdb < features.sql
```

(Requiere DuckDB, porque el script usa `DATE_DIFF` y `DATE_TRUNC`, funciones
propias de ese motor.)

## Fecha de referencia

Todos los calculos usan el **31 de marzo de 2024** como fecha de referencia
fija, en vez de la fecha actual del sistema. Esto es intencional: así el
resultado es siempre el mismo sin importar el dia en que se corra el script,
lo cual es necesario para poder documentar y verificar un resultado esperado
concreto (ver mas abajo).

## Que mide cada feature

### Recency

- **Que mide**: dias transcurridos desde la ultima compra del usuario hasta
  la fecha de referencia.
- **Como se calcula**: `DATE_DIFF('day', MAX(fecha), fecha_referencia)`,
  agrupado por usuario.
- **Nulos**: un usuario que nunca compro no tiene ninguna fecha de la cual
  calcular la diferencia, asi que el resultado crudo es `NULL`. Se reemplaza
  por el valor centinela **999**. Se eligio un numero fijo en vez de, por
  ejemplo, los dias desde el registro del usuario, porque el esquema de
  datos no tiene una fecha de registro disponible; 999 es un valor que
  claramente queda fuera de cualquier rango real de recency, facil de
  identificar como "nunca compro" en pasos posteriores del pipeline de ML.
- **Por que sirve para churn**: a mayor recency, mas tiempo paso desde la
  ultima interaccion del usuario con la tienda, lo cual es un indicador
  clasico de que esta perdiendo interes.

### Frequency

- **Que mide**: cantidad de pedidos distintos realizados por el usuario.
- **Como se calcula**: `COUNT(DISTINCT pedido_id)`, agrupado por usuario.
- **Nulos**: un usuario sin pedidos no tiene filas que contar, pero
  `COUNT()` nunca devuelve `NULL` en ese caso, devuelve 0 directamente, asi
  que no hace falta ningun `COALESCE` aca.
- **Por que sirve para churn**: usuarios con baja frecuencia historica de
  compra son, en general, menos fieles y mas propensos a no volver.

### Monetary

- **Que mide**: gasto total acumulado del usuario en todo el periodo.
- **Como se calcula**: `COALESCE(SUM(monto), 0)`, agrupado por usuario.
- **Nulos**: si el usuario no tiene pedidos, `SUM()` sobre ningun valor da
  `NULL`; se completa con 0 mediante `COALESCE`.
- **Por que sirve para churn**: el valor economico que representa cada
  usuario ayuda a priorizar: no es lo mismo perder a un cliente de alto
  gasto historico que a uno marginal.

### Trend

- **Que mide**: la diferencia entre el gasto del ultimo mes (marzo 2024) y
  el promedio de gasto mensual de los meses anteriores. Un valor positivo
  indica que el usuario esta gastando mas que su historico; uno negativo,
  que esta gastando menos.
- **Como se calcula**: se arma el gasto mensual por usuario con una CTE
  (`mensual`), se promedia ese gasto solo para los meses anteriores a marzo
  usando `AVG(gasto) OVER (PARTITION BY usuario_id)`, y se resta ese
  promedio al gasto puntual de marzo.
- **Punto critico**: el filtro `WHERE mes < DATE '2024-03-01'` excluye
  explicitamente a marzo del promedio historico. Si no se filtrara, el
  promedio quedaria sesgado por el mismo mes que se esta comparando contra
  ese promedio, lo cual invalidaria la metrica.
- **Nulos**: usuarios sin historial previo (como Caro, que solo compro en
  marzo) o sin compras en marzo (como Beto) quedan en 0 para la parte que
  les falta, via `COALESCE`, en vez de `NULL`.
- **Por que sirve para churn**: una tendencia negativa sostenida es una
  señal de alerta temprana, incluso antes de que el usuario deje de comprar
  por completo.

### Ranking de gasto (`ranking_gasto`)

- **Que mide**: la posicion de cada usuario segun su gasto total (`monetary`),
  de mayor a menor.
- **Como se calcula**: `RANK() OVER (ORDER BY monetary DESC)`, la segunda
  funcion de ventana del script (ademas de `AVG() OVER` usada en `trend`).
- **Por que sirve para churn**: perder al usuario con mayor ranking de gasto
  tiene un impacto de negocio distinto a perder al de menor ranking; es una
  feature de contexto relativo, no solo un valor absoluto.

### Churn

- **Que mide**: una etiqueta binaria (0 o 1) que marca si el usuario se
  considera en riesgo de abandono.
- **Como se calcula**: `1` si `frequency = 0` (nunca compro) **o**
  `recency > 60` (mas de 60 dias sin comprar); `0` en caso contrario.
- **Resultado esperado** con los datos de partida: Ana y Caro con
  `churn = 0`; Beto (recency 66) y Dani (nunca compro) con `churn = 1`.

## Salida esperada

| usuario_id | nombre | recency | frequency | monetary | trend | ranking_gasto | churn |
|---|---|---|---|---|---|---|---|
| 1 | Ana | 11 | 3 | 550.0 | 175.0 | 1 | 0 |
| 2 | Beto | 66 | 2 | 300.0 | -300.0 | 2 | 1 |
| 3 | Caro | 3 | 2 | 120.0 | 120.0 | 3 | 0 |
| 4 | Dani | 999 | 0 | 0.0 | 0.0 | 4 | 1 |

## Checklist aplicada antes de entregar

- GROUP BY incluye todas las columnas no agregadas presentes en el SELECT.
- LEFT JOIN usado en `rfm` y `tend`: Dani permanece en el resultado final.
- El periodo de `trend` excluye explicitamente marzo del promedio
  historico (`WHERE mes < DATE '2024-03-01'`).
- COALESCE aplicado en toda agregacion que puede dar NULL (monetary, trend,
  recency).
- Se usan dos funciones de ventana: `AVG() OVER (PARTITION BY ...)` para el
  promedio historico, y `RANK() OVER (ORDER BY ...)` para el ranking de
  gasto.
