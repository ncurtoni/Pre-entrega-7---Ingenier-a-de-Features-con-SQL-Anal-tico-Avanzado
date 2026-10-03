-- Ingenieria de Features con SQL Analitico Avanzado
-- Genera un dataset de entrenamiento (RFM + Trend + Churn) por usuario,
-- a partir de datos crudos de pedidos de e-commerce.
-- Motor: DuckDB (usa DATE_DIFF y DATE_TRUNC, funciones propias de DuckDB).

-- ============================================================
-- Configuracion: esquema y datos de partida
-- ============================================================
-- Dani nunca compro: es a proposito, para confirmar que el LEFT JOIN
-- no lo hace desaparecer del resultado final.

CREATE TABLE usuarios (
    usuario_id INT,
    nombre VARCHAR
);

INSERT INTO usuarios VALUES
    (1, 'Ana'),
    (2, 'Beto'),
    (3, 'Caro'),
    (4, 'Dani');

CREATE TABLE pedidos (
    pedido_id INT,
    usuario_id INT,
    fecha DATE,
    monto DECIMAL(10,2)
);

INSERT INTO pedidos VALUES
    (1, 1, '2024-01-10', 100),
    (2, 1, '2024-02-15', 150),
    (3, 1, '2024-03-20', 300),
    (4, 2, '2024-01-05', 200),
    (5, 2, '2024-01-25', 100),
    (6, 3, '2024-03-05', 50),
    (7, 3, '2024-03-28', 70);

-- Fecha de referencia fija, para que el resultado no cambie segun el
-- dia en que se corra el script.
-- Fecha de referencia: 2024-03-31


-- ============================================================
-- Consulta principal: features RFM + Trend + Churn por usuario
-- ============================================================

WITH rfm AS (
    -- Recency, Frequency, Monetary por usuario.
    -- LEFT JOIN desde usuarios: si alguien no compro nunca (Dani), igual
    -- aparece en el resultado en vez de desaparecer.
    SELECT
        u.usuario_id,
        u.nombre,
        DATE_DIFF('day', MAX(p.fecha), DATE '2024-03-31') AS recency,
        COUNT(DISTINCT p.pedido_id) AS frequency,
        COALESCE(SUM(p.monto), 0) AS monetary
    FROM usuarios u
    LEFT JOIN pedidos p ON u.usuario_id = p.usuario_id
    GROUP BY u.usuario_id, u.nombre
),

mensual AS (
    -- Gasto total agrupado por usuario y mes calendario.
    SELECT
        usuario_id,
        DATE_TRUNC('month', fecha) AS mes,
        SUM(monto) AS gasto
    FROM pedidos
    GROUP BY usuario_id, DATE_TRUNC('month', fecha)
),

hist AS (
    -- Promedio del gasto mensual, SOLO de los meses anteriores a marzo.
    -- El filtro "mes < '2024-03-01'" es critico: si se incluyera marzo,
    -- el promedio historico quedaria sesgado por el mismo mes que se
    -- quiere comparar contra ese promedio.
    SELECT DISTINCT
        usuario_id,
        AVG(gasto) OVER (PARTITION BY usuario_id) AS prom_hist
    FROM mensual
    WHERE mes < DATE '2024-03-01'
),

ultimo AS (
    -- Gasto puntual del ultimo mes (marzo 2024).
    SELECT usuario_id, gasto
    FROM mensual
    WHERE mes = DATE '2024-03-01'
),

tend AS (
    -- Combina ultimo mes vs promedio historico para calcular el trend.
    -- LEFT JOIN + COALESCE: un usuario sin historial previo, o sin
    -- compras en marzo, queda en 0 en vez de NULL.
    SELECT
        u.usuario_id,
        COALESCE(l.gasto, 0) AS gasto_ultimo_mes,
        COALESCE(h.prom_hist, 0) AS prom_hist,
        COALESCE(l.gasto, 0) - COALESCE(h.prom_hist, 0) AS trend
    FROM usuarios u
    LEFT JOIN hist h ON u.usuario_id = h.usuario_id
    LEFT JOIN ultimo l ON u.usuario_id = l.usuario_id
)

-- Consulta final: une RFM y Trend, agrega el ranking de gasto (segunda
-- funcion de ventana) y la etiqueta de churn.
SELECT
    r.usuario_id,
    r.nombre,
    COALESCE(r.recency, 999) AS recency,
    r.frequency,
    r.monetary,
    t.trend,
    RANK() OVER (ORDER BY r.monetary DESC) AS ranking_gasto,
    CASE
        WHEN r.frequency = 0 OR r.recency > 60 THEN 1
        ELSE 0
    END AS churn
FROM rfm r
JOIN tend t ON r.usuario_id = t.usuario_id
ORDER BY r.usuario_id;
