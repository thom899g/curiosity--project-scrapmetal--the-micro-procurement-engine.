#!/usr/bin/env python3
"""
STRATEGY ORCHESTRATOR
Adaptive capital allocation system with reinforcement learning optimization
Architectural choice: Use Firestore as shared state for containerized strategies
to enable horizontal scaling while maintaining consistency.
"""

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
import numpy as np
import pandas as pd
from enum import Enum
from firebase_admin import firestore, initialize_app, credentials
from google.cloud.firestore_v1 import Client as FirestoreClient
import ccxt
from sklearn.ensemble import RandomForestRegressor
from sklearn.preprocessing import StandardScaler
import joblib
import hashlib
import json

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('strategy_orchestrator.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class StrategyType(Enum):
    """Available strategy types with their risk profiles"""
    TRIANGULAR_ARB = "triangular_arb"
    STABLECOIN_MM = "stablecoin_mm"
    STATISTICAL_ARB = "statistical_arb"
    MEAN_REVERSION = "mean_reversion"

@dataclass
class StrategyPerformance:
    """Performance metrics for strategy evaluation"""
    strategy_id: str
    sharpe_ratio: float
    win_rate: float
    max_drawdown: float
    total_pnl: float
    volatility: float
    last_updated: datetime
    
@dataclass
class CapitalAllocation:
    """Capital allocation decision"""
    strategy_id: str
    allocation_percent: float
    allocation_amount: float
    confidence_score: float
    risk_limit: float

class StrategyOrchestrator:
    """Main orchestrator managing multiple trading strategies"""
    
    def __init__(self, firebase_credentials_path: str = "credentials/firebase.json"):
        """
        Initialize the orchestrator with Firebase connection
        Edge case: Graceful degradation if Firebase is unavailable
        """
        try:
            cred = credentials.Certificate(firebase_credentials_path)
            initialize_app(cred)
            self.db: FirestoreClient = firestore.client()
            logger.info("Firestore connection established")
        except Exception as e:
            logger.error(f"Firebase initialization failed: {e}")
            # Fallback to local state (degraded mode)
            self.db = None
            self._local_state = {}
        
        # Initialize strategy registry
        self.strategies: Dict[str, Dict] = {}
        self.performance_history: Dict[str, List[StrategyPerformance]] = {}
        
        # ML model for allocation optimization
        self.allocation_model: Optional[RandomForestRegressor] = None
        self.scaler = StandardScaler()
        self.model_trained_at: Optional[datetime] = None
        
        # Exchange connections
        self.exchanges: Dict[str, ccxt.Exchange] = {}
        self._init_exchanges()
        
        # Capital management
        self.total_capital: float = 0.0
        self.allocations: Dict[str, CapitalAllocation] = {}
        
        # Performance tracking
        self.metrics_collection_interval = 300  # 5 minutes
        
    def _init_exchanges(self) -> None:
        """Initialize exchange connections with error handling"""
        exchanges_to_init = ['binance', 'coinbase', 'kraken']
        
        for exchange_name in exchanges_to_init:
            try:
                exchange_class = getattr(ccxt, exchange_name)
                exchange = exchange_class({
                    'enableRateLimit': True,
                    'timeout': 30000,
                    'rateLimit': 1000,
                })
                
                # Test connection
                exchange.fetch_ticker('BTC/USDT')
                self.exchanges[exchange_name] = exchange
                logger.info(f"Exchange {exchange_name} initialized successfully")
                
            except Exception as e:
                logger.warning(f"Failed to initialize {exchange_name}: {e}")
                # Continue with other exchanges
    
    async def monitor_strategies(self) -> None:
        """Continuous monitoring loop for all strategies"""
        logger.info("Starting strategy monitoring loop")
        
        while True:
            try:
                # 1. Collect performance metrics from all strategies
                await self._collect_performance_metrics()
                
                # 2. Update ML model if enough new data
                if self._should_retrain_model():
                    self._train_allocation_model()
                
                # 3. Optimize capital allocations
                await self._optimize_allocations()
                
                # 4. Enforce risk limits
                self._enforce_risk_limits()
                
                # 5. Update shared state in Firestore
                await self._update_shared_state()
                
                logger.info(f"Monitoring cycle completed at {datetime.now()}")
                
            except Exception as e:
                logger.error(f"Error in monitoring cycle: {e}", exc_info=True)
                # Implement exponential backoff
                await asyncio.sleep(60)
            
            await asyncio.sleep(self.metrics_collection_interval)
    
    async def _collect_performance_metrics(self) -> None:
        """Collect performance metrics from all active strategies"""
        if self.db:
            # Read from Firestore where strategies publish their metrics
            strategies_ref = self.db.collection('strategies').where('status', '==', 'active')
            docs = strategies_ref.stream()
            
            for doc in docs:
                data = doc.to_dict()
                strategy_id = doc.id
                
                perf = StrategyPerformance(
                    strategy_id=strategy_id,
                    sharpe_ratio=data.get('sharpe_ratio', 0.0),
                    win_rate=data.get('win_rate', 0.0),
                    max_drawdown=data.get('max_drawdown', 0.0),
                    total_pnl=data.get('total_pnl', 0.0),
                    volatility=data.get('volatility', 0.0),
                    last_updated=datetime.now()
                )
                
                # Store in local history
                if strategy_id not in self.performance_history:
                    self.performance_history[strategy_id] = []
                self.performance_history[strategy_id].append(perf)
                
                # Keep only last 1000 data points
                if len(self.performance_history[strategy_id]) > 1000:
                    self.performance_history[strategy_id].pop(0)
                
        else:
            # Local mode - simulate strategy performance
            logger.warning("Running in local mode without Firestore")
    
    def _should_retrain_model(self) -> bool:
        """Determine if ML model should be retrained"""
        if not self.model_trained_at:
            return True
        
        # Retrain every 24 hours or if significant market change
        hours_since_training = (datetime.now() - self.model_trained_at).total_seconds() / 3600
        return hours_since_training > 24
    
    def _train_allocation_model(self) -> None:
        """Train Random Forest model for capital allocation"""
        try:
            # Prepare training data
            X, y = self._prepare_training_data()
            
            if len(X) < 100:  # Need sufficient data
                logger.warning("Insufficient data for model training")
                return
            
            # Scale features
            X_scaled = self.scaler.fit_transform(X)
            
            # Train model
            self.allocation_model = RandomForestRegressor(
                n_estimators=100,
                max_depth=10,
                random_state=42,
                n_jobs=-1
            )
            self.allocation_model.fit(X_scaled, y)
            
            self.model_trained_at = datetime.now()
            logger.info(f"Allocation model trained on {len(X)} samples")
            
            # Save model locally
            joblib.dump(self.allocation_model, 'models/allocation_model.joblib')
            
        except Exception as e:
            logger.error(f"Model training failed: {e}", exc_info=True)
    
    def _prepare_training_data(self) -> Tuple[np.ndarray, np.ndarray]:
        """Prepare feature matrix and target variable for ML"""
        features = []
        targets = []
        
        for strategy_id